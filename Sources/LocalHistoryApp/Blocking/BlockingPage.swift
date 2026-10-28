#if os(macOS)
import AppKit
import ServiceManagement
import SwiftUI
import LocalHistoryCore

/// The whole module on one page: what is blocked now, start a block (or freeze the whole Mac),
/// the lists and the week where programs are drawn. Protection sits in a pill by the title.
@MainActor struct BlockingPage: View {
    var onOpenLists: () -> Void = {}
    @ObservedObject private var runtime = BlockingRuntime.shared

    var body: some View {
        if let controller = runtime.controller {
            BlockingPageContent(controller: controller, onOpenLists: onOpenLists)
        } else {
            GoalongModuleOffNote(module: .blocking, text: "Le programme bloque vos listes à heures fixes. Il vient du module Blocage, désactivé.")
        }
    }
}

@MainActor struct BlockingPageContent: View {
    @ObservedObject var controller: BlockingController
    /// Renders and tests pin the clock; the app follows the real one.
    var now: Date?
    var onOpenLists: () -> Void = {}
    @State private var editingList: UUID?
    @State private var stopping: BlockingStopRequest?
    @State private var unlocking: BlockingStopRequest?
    @State private var composing = false

    init(controller: BlockingController, now: Date? = nil, expanded: UUID? = nil, onOpenLists: @escaping () -> Void = {}) {
        self.controller = controller
        self.now = now
        self.onOpenLists = onOpenLists
        _editingList = State(initialValue: expanded)
    }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in // wall: display tick
            let now = self.now ?? GoalongToday.timeline(context.date)
            let frozen = controller.freeze.map { $0.end > now } ?? false
            let blocking = controller.activeBlocks.contains { $0.end > now }
            ScrollView {
                VStack(alignment: .leading, spacing: LHTheme.sectionSpacing) {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .center) {
                            Text("Bloquez vos listes maintenant ou à heures fixes, verrous compris.")
                                .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                            Spacer(minLength: 12)
                            BlockingProtectionPill(controller: controller)
                        }
                        BlockingStateHero(controller: controller, now: now,
                                          onStop: { stopping = BlockingStopRequest(id: $0.id, what: "") },
                                          onUnlock: { block in
                                              unlocking = BlockingStopRequest(id: block.id, what: unlockText(block.origin, end: block.end))
                                          },
                                          onExtraBreak: { controller.extraBreakRequest = $0.id })
                        BlockingScheduledList(controller: controller, now: now,
                                              onTyping: { stopping = BlockingStopRequest(id: $0.id, what: "") },
                                              onPassword: { session in
                                                  unlocking = BlockingStopRequest(id: session.id,
                                                      what: "Le blocage prévu \(BlockingFormat.moment(session.start, now: now)) sera annulé.")
                                              })
                    }
                    if let error = controller.error, editingList == nil {
                        BlockingNoteButton(note: GoalongNote(error, tone: .warning), hint: "Fermer l’erreur") { controller.error = nil }
                            .accessibilityIdentifier("blocking-error")
                    }
                    // Lists are made in Distractions; with none yet, the composer only offers the whole Mac.
                    if controller.lists.isEmpty {
                        // The empty state carries its own way out: a list made here opens in its editor.
                        HStack(spacing: 12) {
                            GoalongNote("Aucune liste pour l’instant. Créez-en une ici ou dans Distractions.", symbol: "list.bullet")
                            Button {
                                let list = BlockList(name: "Ma liste", sites: [], apps: [])
                                controller.save(list)
                                if controller.lists.contains(where: { $0.id == list.id }) { editingList = list.id }
                            } label: { Label("Nouvelle liste", systemImage: "plus") }
                                .buttonStyle(LHSecondaryButtonStyle())
                                .accessibilityIdentifier("blocking-empty-new-list")
                        }
                    }
                    if !frozen {
                        if blocking && !composing {
                            Button { composing = true } label: { Label("Bloquer autre chose", systemImage: "plus") }
                                .buttonStyle(LHQuietButtonStyle())
                                .accessibilityIdentifier("blocking-compose")
                        } else {
                            BlockingNowComposer(controller: controller, now: now)
                        }
                    }
                    if !controller.lists.isEmpty {
                        GoalongSection(title: "Semaine",
                                       subtitle: "Glissez sur un jour, ou utilisez son bouton +, pour programmer un blocage. Cliquez une plage pour la changer.") {
                            BlockingWeekEditor(controller: controller, now: now)
                        }
                    }
                }
                .font(.system(size: 13))
                .frame(maxWidth: LHTheme.readableWidth, alignment: .leading)
                .padding(.horizontal, LHTheme.pageInset).padding(.top, 28).padding(.bottom, LHTheme.pageBottomInset)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(LHTheme.pageBackground)
        .accessibilityIdentifier("blocking-page")
        .onChange(of: controller.activeBlocks.isEmpty) { empty in if empty { composing = false } }
        .sheet(item: $unlocking) { request in
            BlockingPasswordSheet(controller: controller, purpose: .unlock(request.id, what: request.what)) { unlocking = nil }
                .goalongControls()
        }
        .sheet(item: Binding(get: { controller.extraBreakRequest.flatMap(controller.list).map(extraBreakRequest) },
                             set: { if $0 == nil { controller.extraBreakRequest = nil } })) { request in
            BlockingPasswordSheet(controller: controller, purpose: .extraBreak(request.id, what: request.what)) { controller.extraBreakRequest = nil }
                .goalongControls()
        }
        .sheet(item: $stopping) { block in
            BlockingTypingChallengeSheet(text: controller.typingChallenge(for: block.id)) { typed in
                controller.stop(block.id, typed: typed)
                stopping = nil
            } onCancel: { stopping = nil }
            .goalongControls()
        }
        .sheet(isPresented: Binding(get: { editingList != nil }, set: { if !$0 { editingList = nil } })) {
            if let id = editingList {
                BlockListSheet(controller: controller, listID: id, now: now ?? GoalongToday.now) { editingList = nil }
                    .goalongControls()
            }
        }
    }

    private func extraBreakRequest(_ list: BlockList) -> BlockingStopRequest {
        BlockingStopRequest(id: list.id, what: "Toutes les pauses de « \(list.name) » sont prises aujourd’hui. Le mot de passe en accorde une de \(list.breaks?.minutes ?? 0) min de plus.")
    }

    private func unlockText(_ origin: BlockSession.Origin, end: Date) -> String {
        if case .program = origin { return "Cette plage du programme s’arrête pour aujourd’hui. Elle revient la prochaine fois." }
        return "Le blocage s’arrête maintenant, avant \(BlockingFormat.endTime(end))."
    }
}

/// A note that acts on click. A real button, so VoiceOver announces it and the keyboard reaches it.
struct BlockingNoteButton: View {
    let note: GoalongNote
    let hint: String
    var action: () -> Void

    var body: some View {
        Button(action: action) { note.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .help(hint)
            .accessibilityHint(hint)
    }
}

/// A block to stop or cancel, by id: active or scheduled for later.
struct BlockingStopRequest: Identifiable {
    var id: UUID
    var what: String
}

// MARK: - State

/// What blocks now, set on the page: the time left as the one hero figure, then the session
/// drawn as a thread from its start to its end, with the present as a lime point.
@MainActor struct BlockingStateHero: View {
    @ObservedObject var controller: BlockingController
    let now: Date
    var onStop: (BlockingActiveBlock) -> Void
    var onUnlock: (BlockingActiveBlock) -> Void = { _ in }
    var onExtraBreak: (BlockList) -> Void = { _ in }

    /// The strongest block leads, then the one that lasts longest.
    private var blocks: [BlockingActiveBlock] {
        controller.activeBlocks.filter { $0.end > now }.sorted {
            (-$0.lock.strength, -$0.end.timeIntervalSince1970) < (-$1.lock.strength, -$1.end.timeIntervalSince1970)
        }
    }

    var body: some View {
        if let freeze = controller.freeze, freeze.end > now {
            frozen(freeze)
        } else if let main = blocks.first {
            active(main)
        } else {
            idle
        }
    }

    private var idle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "lock.open").font(.system(size: 15, weight: .medium))
                .foregroundStyle(LHTheme.secondaryText).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Rien n’est bloqué").font(LHTheme.sectionTitleFont).tracking(-0.2)
                if let next = controller.nextProgramStart, let list = controller.list(next.listID) {
                    Text("Prochain blocage : \(list.name), \(BlockingFormat.moment(next.date, now: now)).")
                        .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                }
                attemptsLine
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("blocking-state-idle")
    }

    private func active(_ block: BlockingActiveBlock) -> some View {
        let lists = block.listIDs.compactMap(controller.list)
        let others = blocks.dropFirst()
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                lockLine(block)
                if let apps = triggerApps(block) {
                    Text(apps).font(LHTheme.heroFont).tracking(LHTheme.heroTracking).lineLimit(1).minimumScaleFactor(0.6)
                } else {
                    Text(BlockingFormat.remaining(block.end.timeIntervalSince(now)))
                        .font(LHTheme.heroFont).tracking(LHTheme.heroTracking)
                        .goalongNumericTransition()
                        .accessibilityLabel("Encore \(BlockingFormat.remaining(block.end.timeIntervalSince(now)))")
                }
            }
            if triggerApps(block) == nil {
                BlockingSessionThread(start: block.start, end: block.end, now: now, locked: block.lock.protectsLists)
            }
            HStack(alignment: .center, spacing: 12) {
                BlockingIconCluster(lists: lists, size: 22, limit: 7)
                Text(lists.map(\.name).joined(separator: ", "))
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 12)
                actions(block, lists: lists, breaks: true)
            }
            ForEach(lists.filter { block.breakEnds[$0.id] != nil || block.quotaSecondsLeft[$0.id] != nil }) { list in
                allowanceLine(block, list: list)
            }
            attemptsLine
            ForEach(Array(others)) { other in
                Rectangle().fill(LHTheme.separator).frame(height: 1)
                secondary(other)
            }
        }
        .accessibilityIdentifier("blocking-state-active")
    }

    /// « Xcode ouvert » for a block started by a trigger app; nil for a block with an end.
    private func triggerApps(_ block: BlockingActiveBlock) -> String? {
        guard let shown = triggerNames(block) else { return nil }
        guard !shown.isEmpty else { return "App de travail ouverte" }
        return shown.prefix(2).joined(separator: ", ") + (shown.count > 1 ? " ouverts" : " ouvert")
    }

    /// The trigger apps that hold the block (running ones first); nil for a block with an end.
    private func triggerNames(_ block: BlockingActiveBlock) -> [String]? {
        guard case .trigger(let id) = block.origin else { return nil }
        let running = controller.runningAppIDs()
        let apps = controller.list(id)?.triggers?.apps ?? []
        let names = apps.filter { running.contains($0.bundleIdentifier) }.map(\.name)
        return names.isEmpty ? apps.map(\.name) : names
    }

    @ViewBuilder private var attemptsLine: some View {
        let total = controller.totalAttemptsToday
        if total > 0 {
            Text(total == 1 ? "Aujourd’hui : 1 tentative bloquée" : "Aujourd’hui : \(total) tentatives bloquées")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(LHTheme.secondaryText)
                .accessibilityIdentifier("blocking-attempts-today")
        }
    }

    private func lockLine(_ block: BlockingActiveBlock) -> some View {
        var symbol = block.lock.symbol
        var words: String
        switch block.lock {
        case .locked: words = "Verrouillé jusqu’à \(BlockingFormat.endTime(block.end))"
        case .password: words = "Protégé par mot de passe · jusqu’à \(BlockingFormat.endTime(block.end))"
        case .typing: words = "Difficile à arrêter · jusqu’à \(BlockingFormat.endTime(block.end))"
        case .free: words = "Bloqué jusqu’à \(BlockingFormat.endTime(block.end))"
        }
        let lists = block.listIDs.compactMap(controller.list)
        if !lists.isEmpty, lists.allSatisfy({ $0.effectiveAction == .slowDown }) {
            words = words.replacingOccurrences(of: "Bloqué jusqu", with: "Ralenti jusqu")
        }
        let origin: String
        if case .program = block.origin { origin = " · programme" } else { origin = "" }
        if triggerApps(block) != nil {
            words = lists.allSatisfy({ $0.effectiveAction == .slowDown }) ? "Ralenti tant que l’app est ouverte" : "Bloqué tant que l’app est ouverte"
            symbol = "app.badge"
        }
        return Label(words + origin, systemImage: symbol)
            .font(.system(size: 13, weight: .medium))
            .accessibilityIdentifier("blocking-lock-line")
    }

    @ViewBuilder private func actions(_ block: BlockingActiveBlock, lists: [BlockList], breaks: Bool = false) -> some View {
        // Breaks belong to lists: offered once, on the leading block.
        let breakList = breaks ? lists.first { (block.breaksLeft[$0.id] ?? 0) > 0 && block.breakEnds[$0.id] == nil } : nil
        let extraList = breaks && breakList == nil ? lists.first { controller.offersExtraBreak(listID: $0.id) } : nil
        HStack(spacing: 8) {
            if let list = extraList {
                Button { onExtraBreak(list) } label: { Label("Pause supplémentaire…", systemImage: "cup.and.saucer") }
                    .help("Pauses du jour prises. Le mot de passe en accorde une de plus.")
                    .accessibilityIdentifier("blocking-extra-break")
            }
            if let list = breakList, let breaks = list.breaks {
                Button { controller.takeBreak(listID: list.id) } label: {
                    Label("Pause de \(breaks.minutes) min", systemImage: "cup.and.saucer")
                }
                .help("\(FrenchCount.count(block.breaksLeft[list.id] ?? 0, "pause restante", "pauses restantes")) sur \(breaks.count) aujourd’hui")
                .accessibilityIdentifier("blocking-take-break")
            }
            switch block.lock {
            case .free:
                if block.origin.stopsFromPage {
                    Button("Arrêter") { controller.stop(block.id) }.accessibilityIdentifier("blocking-stop")
                }
            case .typing:
                Button("Arrêter…") { onStop(block) }.accessibilityIdentifier("blocking-stop")
            case .password:
                Button { onUnlock(block) } label: { Label("Débloquer…", systemImage: "key") }
                    .accessibilityIdentifier("blocking-unlock")
            case .locked:
                EmptyView()
            }
        }
        .fixedSize()
    }

    private func allowanceLine(_ block: BlockingActiveBlock, list: BlockList) -> some View {
        HStack(spacing: 10) {
            if let end = block.breakEnds[list.id] {
                Image(systemName: "cup.and.saucer").foregroundStyle(LHTheme.secondaryText).frame(width: 16)
                Text("\(list.name) en pause jusqu’à \(BlockingFormat.endTime(end))")
                Spacer(minLength: 8)
                Button("Reprendre") { controller.endBreak(listID: list.id) }.buttonStyle(LHQuietButtonStyle())
            } else if let left = block.quotaSecondsLeft[list.id], let quota = list.quotaMinutesPerDay {
                let earned = Int(controller.earnedMinutesToday[list.id] ?? 0)
                Image(systemName: "hourglass").foregroundStyle(LHTheme.secondaryText).frame(width: 16)
                Text((left > 0 ? "\(list.name) : encore \(BlockingFormat.remaining(left)) aujourd’hui"
                               : "\(list.name) : vos \(BlockingFormat.duration(minutes: quota + earned)) du jour sont passées")
                     + (earned > 0 ? " · \(BlockingFormat.earnedBreak(minutes: earned))" : ""))
                Spacer(minLength: 8)
                BlockingMeter(fraction: 1 - left / Double(max(1, (quota + earned) * 60))).frame(width: 120)
            }
        }
        .font(.system(size: 12)).foregroundStyle(LHTheme.text)
    }

    private func secondary(_ block: BlockingActiveBlock) -> some View {
        let lists = block.listIDs.compactMap(controller.list)
        return HStack(spacing: 12) {
            BlockingIconCluster(lists: lists, size: 18, limit: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(lists.map(\.name).joined(separator: ", ")).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(triggerNames(block).map { "\(BlockingFormat.verb(lists)) \(BlockingFormat.triggerPhrase($0))" }
                     ?? "\(block.lock == .free ? BlockingFormat.verb(lists) : block.lock.title) jusqu’à \(BlockingFormat.endTime(block.end))")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
            Spacer(minLength: 12)
            actions(block, lists: lists)
        }
    }

    private func frozen(_ freeze: BlockFreeze) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Mac gelé jusqu’à \(BlockingFormat.endTime(freeze.end))", systemImage: "snowflake")
                    .font(.system(size: 13, weight: .medium))
                Text(BlockingFormat.remaining(freeze.end.timeIntervalSince(now)))
                    .font(LHTheme.heroFont).tracking(LHTheme.heroTracking)
            }
            BlockingSessionThread(start: freeze.start, end: freeze.end, now: now, locked: true)
        }
        .accessibilityIdentifier("blocking-state-frozen")
    }
}

/// A session drawn as the app's thread: the span is a thick stroke, what has passed is solid,
/// what remains is quieter, and the present is the lime point (where you are).
struct BlockingSessionThread: View {
    let start: Date
    let end: Date
    let now: Date
    var locked = false

    private var progress: Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width, x = width * progress
                ZStack(alignment: .leading) {
                    Capsule().fill(LHTheme.text.opacity(0.16)).frame(height: 8)
                    Capsule().fill(LHTheme.text).frame(width: max(8, x), height: 8)
                    Circle().fill(LHTheme.accent)
                        .overlay(Circle().strokeBorder(LHTheme.pageBackground, lineWidth: 3))
                        .frame(width: 18, height: 18)
                        .offset(x: min(max(0, x - 9), width - 18))
                }
                .frame(height: 18)
            }
            .frame(height: 18)
            HStack {
                Text(BlockingFormat.time(start))
                Spacer()
                if locked { Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)) }
                Text(BlockingFormat.endTime(end))
            }
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(LHTheme.tertiaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("De \(BlockingFormat.time(start)) à \(BlockingFormat.endTime(end)), \(GoalongUIFormat.percent(progress * 100)) écoulés")
    }
}

/// A thin share bar: used part in ink on a sunken track.
struct BlockingMeter: View {
    let fraction: Double
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                // The outline keeps an untouched quota visible on the cream card (≥ 3:1).
                Capsule().fill(LHTheme.insetBackground)
                    .overlay(Capsule().strokeBorder(LHTheme.text.opacity(0.4), lineWidth: 1))
                Capsule().fill(LHTheme.text.opacity(0.75)).frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Start now

/// One sentence to fill: what (lists, or the whole Mac), for how long, how hard to stop.
/// « Tout le Mac » is the freeze: always locked, with the apps the member keeps.
@MainActor struct BlockingNowComposer: View {
    enum Span: Hashable { case minutes(Int), until }

    @ObservedObject var controller: BlockingController
    let now: Date
    @State private var selected: Set<UUID> = []
    @State private var wholeMac = false
    @State private var span: Span = .minutes(60)
    @State private var until = Calendar.current.date(byAdding: .hour, value: 2, to: GoalongToday.now) ?? GoalongToday.now
    @State private var lock: BlockLock = .free
    @State private var freezeMode: BlockFreeze.Mode = .shield
    @State private var kept: [BlockAppRule] = []
    @State private var confirmingLock = false
    @State private var confirmingFreeze = false
    /// The plan the open alert promises: a click on it keeps this end (R5-regressions-01).
    @State private var pending: BlockingNowPlan?
    /// The freeze the open alert promises, read at the click that opened it (B01-R2-01).
    @State private var pendingFreezePromise: BlockingFreezePromise?
    /// That click: the alert writes its end time against it.
    @State private var pendingFreezeAt = GoalongToday.now
    @State private var picking = false
    /// « Plus tard »: a one-time block that starts by itself.
    @State private var later = false
    @State private var startAt = Calendar.current.date(byAdding: .hour, value: 1, to: GoalongToday.now) ?? GoalongToday.now

    init(controller: BlockingController, now: Date, later: Bool = false, lock: BlockLock = .free) {
        self.controller = controller
        self.now = now
        _later = State(initialValue: later)
        _lock = State(initialValue: lock)
        _startAt = State(initialValue: Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now)
    }

    /// Lists only: the whole Mac always starts now.
    private var scheduling: Bool { later && !wholeMac }

    /// The page's `now` moves every 30 s only: it draws the labels; a click reads the clock again.
    private func plan(at date: Date) -> BlockingNowPlan {
        if case .minutes(let value) = span { return BlockingNowPlan(later: scheduling, startAt: startAt, minutes: value, now: date) }
        return BlockingNowPlan(later: scheduling, startAt: startAt, until: until, now: date)
    }
    private var begin: Date { plan(at: now).start }
    /// A « Plus tard » start time already past starts now: the button must say so.
    private var startsLater: Bool { plan(at: now).startsLater }
    private var end: Date { plan(at: now).end }

    /// What the freeze button promises: the end the engine will store, or its 5 min minimum.
    private var freezePromise: BlockingFreezePromise { BlockingFreezePromise(end: end, now: now) }

    private var startHint: String? {
        BlockingProtectionDetails.startHint(wholeMac: wholeMac, frozen: controller.freeze != nil, hasLists: !controller.lists.isEmpty,
                                            anySelected: !selected.isDisjoint(with: controller.lists.map(\.id)),
                                            needsPassword: lock == .password && !controller.hasPassword)
    }

    private var actionTitle: String {
        if wholeMac { return "Geler \(freezePromise.phrase(now: now))…" }
        return plan(at: now).actionTitle()
    }

    /// The plan a click on the main button promises. A duration counts from the click. A « Jusqu’à… »
    /// time keeps the day the button showed: a time reached since the last tick is refused, never
    /// moved to the next day.
    private func promised(at date: Date) -> BlockingNowPlan? {
        if case .minutes = span { return plan(at: date) }
        return plan(at: now).confirmed(at: date)
    }

    /// The freeze the alert promises, read when it opened.
    private var pendingFreeze: BlockingFreezePromise { pendingFreezePromise ?? freezePromise }

    /// Why a click came too late, in the words of the chosen span: a duration has no end time to change.
    nonisolated static func refusal(_ span: Span, freeze: Bool) -> String {
        switch (span, freeze) {
        case (.minutes, false): return "Ce blocage serait déjà fini. Relancez-le."
        case (.until, false): return "L’heure de fin est passée. Choisissez une autre heure."
        case (.minutes, true): return "Le gel durerait moins de 5 min. Relancez-le."
        case (.until, true): return "Le gel durerait moins de 5 min. Choisissez une autre heure."
        }
    }

    private func refuseEndPassed(freeze: Bool = false) {
        controller.error = Self.refusal(span, freeze: freeze)
    }

    private func confirm() {
        let date = Date() // wall: page input; the controller moves it to its trusted frame
        if wholeMac {
            // The freeze promises what the button showed; its 5 min minimum covers an end time just reached.
            let shown: BlockingNowPlan
            if case .minutes = span { shown = plan(at: date) } else { shown = plan(at: now) }
            pending = shown
            // Promised from the click, not the page tick (up to 30 s old), with time to read the alert.
            pendingFreezePromise = BlockingFreezePromise.alert(end: shown.end, click: date)
            pendingFreezeAt = date
            confirmingFreeze = true
            return
        }
        guard let shown = promised(at: date) else { return refuseEndPassed() }
        pending = shown
        if lock.protectsLists { confirmingLock = true } else { start(shown) }
    }

    var body: some View {
        GoalongSection(title: "Bloquer") {
            LHCard {
                VStack(alignment: .leading, spacing: 16) {
                    row("Quoi") {
                        BlockingFlow(spacing: 8) {
                            ForEach(controller.lists) { list in
                                BlockingListChip(list: list, selected: !wholeMac && selected.contains(list.id)) {
                                    wholeMac = false
                                    if selected.contains(list.id) { selected.remove(list.id) } else { selected.insert(list.id) }
                                }
                            }
                            BlockingNewListChip { id in wholeMac = false; selected.insert(id) }
                            BlockingWholeMacChip(selected: wholeMac) { wholeMac.toggle() }
                        }
                    }
                    if !wholeMac {
                        row("Quand") {
                            HStack(spacing: 10) {
                                GoalongSegmentedControl("Quand", selection: $later, options: [false, true]) {
                                    $0 ? "Plus tard" : "Maintenant"
                                }
                                if later {
                                    DatePicker("Début", selection: $startAt, in: now..., displayedComponents: [.date, .hourAndMinute])
                                        .labelsHidden().fixedSize()
                                        .environment(\.locale, Locale(identifier: "fr_FR"))
                                        .accessibilityIdentifier("blocking-start-at")
                                }
                            }
                        }
                    }
                    row("Pendant") {
                        HStack(spacing: 10) {
                            GoalongSegmentedControl("Durée", selection: $span,
                                                    options: [.minutes(25), .minutes(60), .minutes(120), .minutes(240), .until]) {
                                switch $0 {
                                case .minutes(let value): return BlockingFormat.duration(minutes: value)
                                case .until: return "Jusqu’à…"
                                }
                            }
                            if span == .until {
                                DatePicker("Heure de fin", selection: $until, displayedComponents: .hourAndMinute)
                                    .labelsHidden().fixedSize()
                                    .environment(\.locale, Locale(identifier: "fr_FR"))
                            }
                        }
                    }
                    if wholeMac {
                        row("Écran") {
                            VStack(alignment: .leading, spacing: 10) {
                                GoalongSegmentedControl("Écran", selection: $freezeMode, options: BlockFreeze.Mode.allCases) {
                                    $0 == .shield ? "Écran Goalong" : "Session verrouillée"
                                }
                                if freezeMode == .shield {
                                    BlockingFlow(spacing: 6) {
                                        ForEach(kept) { app in
                                            BlockingItemChip(item: .app(app), removable: true) { kept.removeAll { $0 == app } }
                                        }
                                        Button { picking = true } label: { Label("Garder une app", systemImage: "plus") }
                                            .buttonStyle(LHQuietButtonStyle())
                                            .accessibilityIdentifier("blocking-freeze-keep")
                                            .popover(isPresented: $picking) {
                                                BlockingAppPicker(excluded: Set(kept.map(\.bundleIdentifier))) { kept.append($0) }
                                            }
                                    }
                                }
                                BlockingLockExplainer(lock: .locked,
                                                      text: freezeMode == .shield
                                                          ? "Un écran Goalong couvre tout, sauf les apps gardées. Toujours verrouillé."
                                                          : "macOS verrouille la session, et la reverrouille à chaque ouverture. Toujours verrouillé.")
                            }
                        }
                    } else {
                        row("Arrêt") { BlockingLockPicker(controller: controller, lock: $lock) }
                    }
                    HStack {
                        Spacer()
                        if let hint = startHint {
                            Text(hint).font(.system(size: 12)).foregroundStyle(LHTheme.tertiaryText)
                                .accessibilityIdentifier("blocking-start-hint")
                        }
                        Button { confirm() } label: {
                            Label(actionTitle, systemImage: wholeMac ? "snowflake" : (startsLater ? "calendar" : lock.symbol))
                        }
                        .buttonStyle(LHPrimaryButtonStyle())
                        .disabled(wholeMac ? controller.freeze != nil
                                           : selected.isDisjoint(with: controller.lists.map(\.id)) || (lock == .password && !controller.hasPassword))
                        .accessibilityIdentifier(wholeMac ? "blocking-freeze" : "blocking-start")
                    }
                }
            }
            .onAppear { if selected.isEmpty, let first = controller.lists.first { selected = [first.id] } }
            .alert((pending ?? plan(at: now)).lockTitle(lock), isPresented: $confirmingLock) {
                Button("Annuler", role: .cancel) {}
                Button(lock == .password ? "Protéger" : "Verrouiller") { if let pending { start(pending) } }
            } message: {
                Text(GuardConsent.message((pending ?? plan(at: now)).lockMessage(lock), needed: controller.guardNeedsConsent))
            }
            .alert("Geler le Mac \(pendingFreeze.phrase(now: pendingFreezeAt)) ?", isPresented: $confirmingFreeze) {
                Button("Annuler", role: .cancel) {}
                Button("Geler") {
                    // Never later than the alert said: an end the engine would push back is refused (B01-R1-02).
                    guard let end = pendingFreeze.end(at: Date()) else { return refuseEndPassed(freeze: true) } // wall: page input; the controller moves it to its trusted frame
                    controller.startFreeze(until: end, mode: freezeMode, allowedApps: freezeMode == .shield ? kept : [])
                    wholeMac = false
                }
            } message: {
                Text(GuardConsent.message("\(pendingFreeze.phrase(now: pendingFreezeAt).capitalizedFirst), seul\(kept.isEmpty || freezeMode != .shield ? " Goalong reste accessible" : "es les apps gardées restent accessibles"). Impossible d’annuler. Éteindre le Mac reste possible ; au redémarrage, le gel reprend.",
                                          needed: controller.guardNeedsConsent))
            }
        }
    }

    /// Keeps the promised end and reads the clock for the start only: a start time that has just passed
    /// starts the block now. An end already reached is refused, never moved to the next day.
    private func start(_ promised: BlockingNowPlan) {
        let ids = controller.lists.map(\.id).filter(selected.contains)
        guard let plan = promised.confirmed(at: Date()) else { return refuseEndPassed() } // wall: page input; the controller moves it to its trusted frame
        if plan.startsLater {
            if controller.schedule(listIDs: ids, start: plan.start, end: plan.end, lock: lock) != nil { later = false }
        } else {
            controller.start(listIDs: ids, until: plan.end, lock: lock)
            later = false
        }
    }

    /// The label sits on the centre line of the first row of controls (32 points high).
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                .frame(width: 64, height: 32, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The composer's start and end, from one clock reading. A start time already past starts now.
struct BlockingNowPlan: Equatable {
    var start: Date
    var end: Date
    var now: Date
    var startsLater: Bool { start > now }

    init(later: Bool, startAt: Date, minutes: Int, now: Date) {
        self.now = now
        start = later ? max(startAt, now) : now
        end = start.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// « Jusqu’à… »: a time not after the start means the next day.
    init(later: Bool, startAt: Date, until: Date, now: Date, calendar: Calendar = .current) {
        self.now = now
        start = later ? max(startAt, now) : now
        let parts = calendar.dateComponents([.hour, .minute], from: until)
        end = BlockingWallClock.next(hour: parts.hour ?? 0, minute: parts.minute ?? 0, after: start, calendar: calendar)
    }

    /// The plan at the click that confirms it: the promised end stays, only the start reads the clock.
    /// Nil when that end is passed or less than a minute away (R5-regressions-01).
    func confirmed(at date: Date) -> BlockingNowPlan? {
        var plan = self
        plan.start = startsLater ? max(start, date) : date
        plan.now = date
        return plan.end.timeIntervalSince(plan.start) >= 60 ? plan : nil
    }

    /// « Programmer » only while the start is still ahead: a start time already past starts now.
    func actionTitle(calendar: Calendar = .current) -> String {
        startsLater ? "Programmer \(BlockingFormat.moment(start, now: now, calendar: calendar))"
                    : "Bloquer \(BlockingFormat.until(end, now: now, calendar: calendar))"
    }

    /// The lock alert says the day: « Verrouiller jusqu’à demain à 2:00 ? », « Verrouiller samedi de 10:00 à 12:00 ? ».
    func lockTitle(_ lock: BlockLock, calendar: Calendar = .current) -> String {
        let when = startsLater ? BlockingFormat.period(from: start, to: end, now: now, calendar: calendar)
                               : BlockingFormat.until(end, now: now, calendar: calendar)
        return (lock == .password ? "Protéger par mot de passe " : "Verrouiller ") + when + " ?"
    }

    func lockMessage(_ lock: BlockLock, calendar: Calendar = .current) -> String {
        let deadline = BlockingFormat.deadline(end, now: now, calendar: calendar)
        let until = BlockingFormat.untilPhrase(deadline)
        return lock == .password
            ? "Sans le mot de passe, ce blocage va \(until). Ses listes peuvent seulement devenir plus strictes, et quitter Goalong demande le mot de passe."
            : "Personne ne pourra arrêter ce blocage avant \(deadline), ni le modifier sauf pour le rendre plus strict. Quitter Goalong ou redémarrer ne l’arrête pas."
    }
}

/// What the freeze alert promises. The engine stores at least 5 min from its own clock: an end time it
/// would push back is promised as « pendant 5 min », counted from the click, so the freeze never ends later
/// than the alert said.
enum BlockingFreezePromise: Equatable {
    case until(Date)
    case minimum

    static let minimumSeconds: TimeInterval = 5 * 60
    /// Time left to read the alert before « Geler »: an end closer than 5 min + this is promised as the minimum.
    static let readingSeconds: TimeInterval = 60

    /// `margin` keeps an end time the engine could still take, but not after a read of the alert, out of `.until`.
    init(end: Date, now: Date, margin: TimeInterval = 0) {
        let bounded = BlockingWallClock.freezeEnd(end, now: now)
        let tight = bounded < now.addingTimeInterval(Self.minimumSeconds + margin)
        self = bounded > end || tight ? .minimum : .until(bounded)
    }

    /// What the alert promises, read at the click on the button that opens it (B01-R2-01).
    static func alert(end: Date, click: Date) -> BlockingFreezePromise {
        BlockingFreezePromise(end: end, now: click, margin: readingSeconds)
    }

    /// The end for a click at `date`; nil when the engine would move the promised end later.
    func end(at date: Date) -> Date? {
        switch self {
        case .minimum: return date.addingTimeInterval(Self.minimumSeconds)
        case .until(let end): return end.timeIntervalSince(date) >= Self.minimumSeconds ? end : nil
        }
    }

    /// « jusqu’à 12:30 », « pendant 5 min ».
    func phrase(now: Date, calendar: Calendar = .current) -> String {
        switch self {
        case .minimum: return "pendant \(BlockingFormat.duration(minutes: Int(Self.minimumSeconds / 60)))"
        case .until(let end): return BlockingFormat.until(end, now: now, calendar: calendar)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// « Tout le Mac » next to the lists: the freeze, drawn as a small covered screen.
struct BlockingWholeMacChip: View {
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "snowflake").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? LHTheme.accent : LHTheme.secondaryText)
                Text("Tout le Mac").font(.system(size: 13, weight: .medium))
                Image(systemName: selected ? "checkmark" : "plus").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(selected ? LHTheme.accent : LHTheme.tertiaryText)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background {
                let shape = RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
                shape.fill(selected ? LHTheme.selectionBackground : LHTheme.controlBackground)
                    .overlay(shape.strokeBorder(selected ? LHTheme.accent : LHTheme.controlBorder,
                                                style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: selected ? [] : [4, 3])))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tout le Mac, geler")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("blocking-pick-mac")
    }
}

/// Four ways to end a block, shown as what it costs to stop: nothing, a chore, someone else, impossible.
struct BlockingLockExplainer: View {
    let lock: BlockLock
    var text: String?
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<4) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(index < level ? LHTheme.text : LHTheme.text.opacity(0.16))
                        .frame(width: 14, height: 4)
                }
            }
            .accessibilityHidden(true)
            Text(text ?? defaultText).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var level: Int { lock.strength + 1 }
    private var defaultText: String {
        switch lock {
        case .free: return "Vous pouvez arrêter à tout moment."
        case .typing: return "Pour arrêter, recopiez un texte de 120 caractères."
        case .password: return "Pour arrêter, il faut le mot de passe de blocage. Confiez-le à un proche."
        case .locked: return "Goalong ne propose aucun moyen d’arrêter avant la fin."
        }
    }
}

// MARK: - Protection

/// How strong the protection is, as one quiet pill by the title; the details open in a popover.
/// A missing permission turns it into a warning, since sites are then not covered.
@MainActor struct BlockingProtectionPill: View {
    @ObservedObject var controller: BlockingController
    @State private var open = false

    var body: some View {
        let ok = controller.siteBlockingAvailable
        // A rounded rectangle like the other controls: a capsule drew square stubs at its two ends.
        let shape = RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous)
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: ok ? "shield.lefthalf.filled" : "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                Text(ok ? (controller.protection.level == .strict ? "Protection renforcée" : "Protection standard")
                        : "Sites non couverts")
                    .font(.system(size: 12, weight: .medium))
            }
            .fixedSize()
            .foregroundStyle(ok ? LHTheme.secondaryText : LHTheme.warning)
            .padding(.horizontal, 10).frame(height: 26)
            .background(shape.fill(LHTheme.controlBackground))
            .overlay(shape.strokeBorder(LHTheme.controlBorder))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("blocking-protection")
        .background(Color.clear.popover(isPresented: $open, arrowEdge: .bottom) {
            BlockingProtectionDetails(controller: controller)
                .padding(18).frame(width: 440)
                .goalongControls()
        })
    }
}

@MainActor struct BlockingProtectionDetails: View {
    @ObservedObject var controller: BlockingController
    @State private var passwordPurpose: BlockingPasswordSheet.Purpose?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Protection").font(LHTheme.cardTitleFont)
            VStack(spacing: 0) {
                statusRow(symbol: "arrow.clockwise", title: "Relance à l’ouverture de session",
                          ok: controller.protection.launchAtLogin,
                          value: controller.protection.launchAtLogin ? "Active" : "Pas encore",
                          action: controller.protection.launchAtLogin ? nil : loginItemsButton)
                GoalongRowDivider()
                statusRow(symbol: "globe", title: "Lecture des adresses",
                          ok: controller.siteBlockingAvailable,
                          value: controller.siteBlockingAvailable ? "Autorisée" : "Nécessaire pour les sites")
                if !controller.browsers.isEmpty {
                    GoalongRowDivider()
                    browsersRow
                }
                GoalongRowDivider()
                passwordRow
                GoalongRowDivider()
                statusRow(symbol: "shield.lefthalf.filled", title: "Niveau",
                          ok: Self.levelIsSettled(controller.protection),
                          value: Self.levelLabel(controller.protection))
                if let help = Self.levelHelp(controller.protection) {
                    // A failed service names where to repair it: its background item in Ouverture.
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(help).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        loginItemsButton
                    }
                        .padding(.leading, 32).padding(.bottom, 8)
                        .accessibilityIdentifier("blocking-level-help")
                }
            }
            if controller.canRemoveGuard {
                // Without any lock, running, planned or weekly: the member may take the background service away.
                Button("Retirer le service de protection") { controller.removeGuardService() }
                    .buttonStyle(LHQuietButtonStyle())
                    .accessibilityIdentifier("blocking-remove-guard")
            }
            GoalongDisclosureGroup("Ce qui reste contournable") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Self.limits, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(LHTheme.tertiaryText)
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).padding(.top, 10)
            }
            .accessibilityIdentifier("blocking-limits")
        }
        .font(.system(size: 13))
        .sheet(isPresented: Binding(get: { passwordPurpose != nil }, set: { if !$0 { passwordPurpose = nil } })) {
            if let purpose = passwordPurpose {
                BlockingPasswordSheet(controller: controller, purpose: purpose) { passwordPurpose = nil }
                    .goalongControls()
            }
        }
    }

    /// « Renforcé » only while the kill guard answers; otherwise what stops it, never an alert (spec K §6).
    static func levelLabel(_ protection: BlockingProtectionState) -> String {
        if protection.level == .strict { return "Renforcé" }
        switch protection.guardian {
        case .awaitingApproval: return "À autoriser dans Réglages Système › Général › Ouverture"
        case .failed: return "Indisponible"
        case .running, .notInstalled: return "Standard"
        }
    }

    /// Why the guard is unavailable, under « Niveau »: its own words, never an alert (R5-garde-01).
    static func levelHelp(_ protection: BlockingProtectionState) -> String? {
        guard protection.level != .strict, case .failed(let reason) = protection.guardian else { return nil }
        return reason
    }

    /// « Standard » is a normal level, not something missing: only a guard waiting or failed keeps the dashed circle.
    static func levelIsSettled(_ protection: BlockingProtectionState) -> Bool {
        if protection.level == .strict { return true }
        switch protection.guardian {
        case .awaitingApproval, .failed: return false
        case .running, .notInstalled: return true
        }
    }

    /// Why the start button is off, or nil when it is on.
    static func startHint(wholeMac: Bool, frozen: Bool, hasLists: Bool, anySelected: Bool, needsPassword: Bool) -> String? {
        if wholeMac { return frozen ? "Le Mac est déjà gelé." : nil }
        if !hasLists { return "Créez une liste, ou choisissez « Tout le Mac »." }
        if !anySelected { return "Choisissez au moins une liste." }
        if needsPassword { return "Choisissez d’abord un mot de passe de blocage." }
        return nil
    }

    /// The blocking password: set it here, or with the « Mot de passe » lock when first chosen.
    private var passwordRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "key").font(.system(size: 13, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                .frame(width: 20).accessibilityHidden(true)
            Text("Mot de passe de blocage").font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            if controller.hasPassword {
                Menu("Défini") {
                    Button("Changer…") { passwordPurpose = .change }
                    Button("Supprimer…") { passwordPurpose = .remove }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .foregroundStyle(LHTheme.secondaryText)
            } else {
                Button("Choisir…") { passwordPurpose = .create }.buttonStyle(LHQuietButtonStyle())
            }
        }
        .frame(minHeight: 38)
        .accessibilityIdentifier("blocking-password-row")
    }

    /// What the Standard level cannot stop. Kept in step with docs/BLOCKING.md.
    static let limits = [
        "Forcer Goalong à quitter arrête le blocage jusqu’à la prochaine ouverture de session, même avec un mot de passe.",
        "Retirer Goalong des éléments d’ouverture, ou supprimer l’app à la main, met fin au blocage.",
        "Supprimer le dossier de blocage puis relancer Goalong efface les verrous.",
        "Changer l’heure du Mac puis redémarrer peut raccourcir un verrou.",
        "Un navigateur que Goalong ne connaît pas, et dont il ne lit pas l’adresse, n’est pas couvert.",
        "Un onglet en arrière-plan continue (son, téléchargement) jusqu’à ce qu’il passe devant.",
        "Un autre compte utilisateur du Mac n’est pas bloqué.",
    ]

    /// Réglages Système › Général › Ouverture, where macOS lets Goalong start and run in the background.
    private var loginItemsButton: AnyView {
        AnyView(Button("Ouvrir Réglages…") { SMAppService.openSystemSettingsLoginItems() }
            .buttonStyle(LHSecondaryButtonStyle()).controlSize(.small)
            .help("Autorisez Goalong dans Réglages Système › Général › Ouverture.")
            .accessibilityIdentifier("blocking-open-login-items"))
    }

    private func statusRow(symbol: String, title: String, ok: Bool, value: String, action: AnyView? = nil) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                    .frame(width: 20).accessibilityHidden(true)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 12)
                Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(ok ? LHTheme.success : LHTheme.tertiaryText).accessibilityHidden(true)
                Text(value).foregroundStyle(LHTheme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            if let action { action }
        }
        .frame(minHeight: 38)
    }

    private var browsersRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "macwindow").font(.system(size: 13, weight: .medium)).foregroundStyle(LHTheme.secondaryText)
                .frame(width: 20).accessibilityHidden(true)
            Text("Navigateurs").font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                ForEach(controller.browsers) { browser in
                    ZStack(alignment: .bottomTrailing) {
                        AppIconView(bundleIdentifier: browser.bundleIdentifier, appName: browser.name, size: 20)
                            .opacity(browser.supported ? 1 : 0.45)
                        Image(systemName: browser.supported ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(browser.supported ? LHTheme.success : LHTheme.secondaryText)
                            .background(Circle().fill(LHTheme.cardBackground).padding(1))
                            .offset(x: 3, y: 3)
                    }
                    .help(browser.supported ? "\(browser.name) : sites bloqués un par un"
                                            : "\(browser.name) : adresse illisible, couvert pendant un blocage de sites")
                    .accessibilityLabel("\(browser.name), \(browser.supported ? "pris en charge" : "couvert pendant un blocage")")
                }
            }
        }
        .frame(minHeight: 42)
    }
}

// MARK: - Stop with effort

/// « Difficile »: retype the text, character by character. Pasting is refused.
struct BlockingTypingChallengeSheet: View {
    let text: String
    var onSubmit: (String) -> Void
    var onCancel: () -> Void
    @State private var typed = ""

    private var matched: Int { zip(text, typed).prefix { $0 == $1 }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recopier pour arrêter").font(LHTheme.sheetTitleFont).tracking(-0.4)
                Text("Le blocage s’arrête quand le texte est identique. Le collage est refusé.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
            Text(groups(text, matched: matched))
                .font(.system(size: 15, design: .monospaced)).lineSpacing(6)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(LHTheme.insetBackground, in: RoundedRectangle(cornerRadius: LHTheme.controlRadius, style: .continuous))
                .textSelection(.disabled)
            TextField("Recopiez ici", text: Binding(get: { typed }, set: { value in
                // One character at a time: a jump of several characters is a paste.
                if value.count <= typed.count + 1 { typed = value }
            }))
                // 14 pt monospaced text is 17 pt high: 8 + 17 + 9 fills the 34 pt field.
                .textFieldStyle(GoalongFieldStyle(textFont: .monospaced14))
                .accessibilityIdentifier("blocking-typing-field")
            HStack {
                BlockingMeter(fraction: Double(matched) / Double(max(1, text.count))).frame(width: 160)
                Text("\(matched) / \(text.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(LHTheme.secondaryText)
                Spacer()
                Button("Continuer le blocage", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Arrêter") { onSubmit(typed) }
                    .buttonStyle(LHPrimaryButtonStyle())
                    .disabled(typed != text)
            }
        }
        .padding(28).frame(width: 560)
        .background(LHTheme.pageBackground)
    }

    private func groups(_ value: String, matched: Int) -> AttributedString {
        var result = AttributedString()
        for (index, character) in value.enumerated() {
            if index > 0, index % 5 == 0 { result.append(AttributedString(index % 30 == 0 ? "\n" : " ")) }
            var part = AttributedString(String(character))
            part.foregroundColor = index < matched ? LHTheme.tertiaryText : LHTheme.text
            result.append(part)
        }
        return result
    }
}
#endif
