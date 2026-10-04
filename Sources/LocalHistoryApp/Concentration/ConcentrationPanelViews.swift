#if os(macOS)
import AppKit
import SwiftUI

/// Shows one Concentration panel at a time, top centre of the screen under the pointer.
/// Non-activating: the member's app keeps the focus; the review note field still takes typing.
@MainActor final class ConcentrationPanelPresenter {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
    private var panel: Panel?

    func show(_ content: FocusPanel, controller: ConcentrationController) {
        let width = ConcentrationPanelView.width(content.kind)
        let host = NSHostingView(rootView: ConcentrationPanelView(content: content, controller: controller)
            .frame(width: width).fixedSize(horizontal: false, vertical: true).goalongControls())
        host.sizingOptions = []
        let size = CGSize(width: width, height: ceil(max(56, host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1_280, height: 800)
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 14,
                           width: size.width, height: size.height)
        let value = panel ?? {
            let made = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            made.isReleasedWhenClosed = false; made.isFloatingPanel = true; made.hidesOnDeactivate = false
            made.level = .floating; made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            made.isOpaque = false; made.backgroundColor = .clear; made.hasShadow = true
            return made
        }()
        value.contentView = host
        value.setFrame(frame, display: true)
        value.orderFrontRegardless()
        panel = value
    }

    func close() { panel?.orderOut(nil); panel?.close(); panel = nil }
}

/// Picks the view for a panel and wires it to the controller's actions.
@MainActor struct ConcentrationPanelView: View {
    let content: FocusPanel
    @ObservedObject var controller: ConcentrationController

    /// Panels take the height of their content.
    static func width(_ kind: FocusPanel.Kind) -> CGFloat {
        switch kind {
        case .phase: return 380
        case .sessionReview: return 460
        case .morning, .evening, .limit, .commitment: return 420
        }
    }

    var body: some View {
        switch content.kind {
        case .phase:
            FocusPhaseNotice(isWork: controller.phase?.isWork ?? content.text.hasPrefix("On reprend"),
                             intent: controller.currentSession?.intent, endsAt: controller.phase?.endsAt,
                             fallback: content.text)
        case .sessionReview:
            let session = controller.sessions.first { $0.id == content.sessionID }
            FocusReviewPanelView(intent: session?.intent ?? "", seconds: session.map { FocusPanelMath.workSeconds($0) } ?? 0,
                                 facts: controller.sessionFacts,
                                 onAnswer: { outcome, note in
                                     guard let id = content.sessionID else { return }
                                     do { try controller.recordOutcome(sessionID: id, outcome: outcome, note: note) }
                                     catch { controller.error = FocusUIError.message(error) }
                                 },
                                 onClose: { controller.dismissPanel() })
        case .morning, .evening:
            FocusPromptPanelView(morning: content.kind == .morning, onNow: { controller.promptNow() }, onLater: { controller.promptLater() })
        case .limit:
            FocusLimitPanelView(text: content.text, onClose: { controller.dismissPanel() })
        case .commitment:
            Text(content.text) // TODO(design)
        }
    }
}

enum FocusPanelMath {
    static func workSeconds(_ session: FocusSession) -> TimeInterval {
        FocusMeasurement.workIntervals(session, until: session.endedAt ?? Date()).reduce(0) { $0 + $1.duration }
    }
}

/// The raised surface every panel sits on, with the only shadow of the app (set on the window).
private struct FocusPanelSurface<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(GoalongSurface(corner: 14, fill: LHTheme.elevatedBackground, highlighted: true))
            .foregroundStyle(LHTheme.text)
            .font(.system(size: 13))
    }
}

/// Six seconds at a phase change: what starts, and until when.
struct FocusPhaseNotice: View {
    let isWork: Bool
    let intent: String?
    let endsAt: Date?
    var fallback = ""

    var body: some View {
        FocusPanelSurface {
            HStack(spacing: 14) {
                Image(systemName: isWork ? "scope" : "cup.and.saucer").font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isWork ? LHTheme.accent : LHTheme.secondaryText)
                    .frame(width: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("concentration-phase-notice")
    }

    private var title: String {
        guard let endsAt else { return fallback }
        return isWork ? "On reprend jusqu’à \(BlockingFormat.time(endsAt))" : "Pause jusqu’à \(BlockingFormat.time(endsAt))"
    }

    private var detail: String {
        if isWork { return intent ?? fallback }
        return "Le travail reprend seul à la fin."
    }
}

/// « C’est fait ? » after a session: the measured facts of the interval, then three answers.
struct FocusReviewPanelView: View {
    let intent: String
    let seconds: TimeInterval
    let facts: FocusFacts
    var onAnswer: (FocusSession.Outcome?, String?) -> Void
    var onClose: () -> Void
    @State private var note = ""

    var body: some View {
        FocusPanelSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("C’est fait ?").font(LHTheme.cardTitleFont)
                        Text(seconds >= 60 ? "\(intent) · \(BlockingFormat.duration(minutes: Int((seconds / 60).rounded())))" : intent)
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(LHTheme.secondaryText)
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Fermer sans répondre")
                    .accessibilityLabel("Fermer sans répondre")
                }
                FocusFactsView(facts: facts)
                TextField("Une note, si vous voulez", text: $note)
                    .textFieldStyle(GoalongFieldStyle())
                    .onChange(of: note) { value in if value.count > 140 { note = String(value.prefix(140)) } }
                    .accessibilityIdentifier("concentration-review-note")
                HStack(spacing: 8) {
                    Spacer()
                    Button("Non") { answer(.notDone) }
                    Button("En partie") { answer(.partly) }
                    Button("Oui") { answer(.done) }.buttonStyle(LHPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .accessibilityIdentifier("concentration-review-panel")
    }

    private func answer(_ outcome: FocusSession.Outcome) {
        let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
        onAnswer(outcome, value.isEmpty ? nil : value)
    }
}

/// What was measured during a session: active time split as the data colours, then two facts.
struct FocusFactsView: View {
    let facts: FocusFacts

    var body: some View {
        if facts.available, facts.activeSeconds >= 60 {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { proxy in
                    let parts = [(facts.workSeconds, LHTheme.workData), (facts.otherSeconds, LHTheme.otherData),
                                 (facts.unclassifiedSeconds, LHTheme.unclassifiedData)].filter { $0.0 > 0 }
                    let total = max(1, parts.reduce(0) { $0 + $1.0 })
                    let room = proxy.size.width - CGFloat(max(0, parts.count - 1)) * 2
                    HStack(spacing: 2) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                            RoundedRectangle(cornerRadius: LHTheme.markRadius, style: .continuous).fill(part.1)
                                .frame(width: max(3, room * CGFloat(part.0 / total)))
                        }
                    }
                }
                .frame(height: 8)
                .accessibilityHidden(true)
                HStack(spacing: 14) {
                    value("Travail", facts.workSeconds, LHTheme.workData)
                    value("Hors travail", facts.otherSeconds, LHTheme.otherData)
                    value("À classer", facts.unclassifiedSeconds, LHTheme.unclassifiedData)
                }
                Text("\(facts.appSwitches) changement\(facts.appSwitches > 1 ? "s" : "") d’app · plus longue plage sur une chose : \(BlockingFormat.duration(minutes: max(1, Int((facts.longestStretchSeconds / 60).rounded()))))")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("Pas de mesure pour cette séance : l’historique de ce Mac n’était pas enregistré.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func value(_ title: String, _ seconds: Double, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 8, height: 8)
            Text("\(title) \(BlockingFormat.duration(minutes: Int((seconds / 60).rounded())))")
                .font(.system(size: 12).monospacedDigit())
        }
    }
}

/// The morning plan or the evening review, offered once (and once again 30 minutes later).
struct FocusPromptPanelView: View {
    let morning: Bool
    var onNow: () -> Void
    var onLater: () -> Void

    var body: some View {
        FocusPanelSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: morning ? "sunrise" : "moon").font(.system(size: 18, weight: .medium))
                        .foregroundStyle(LHTheme.secondaryText).frame(width: 26).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(morning ? "Plan du matin" : "Bilan du soir").font(.system(size: 14, weight: .semibold))
                        Text(morning ? "Une à dix tâches pour aujourd’hui." : "Ce qui est fait, et ce qui passe à demain.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Plus tard", action: onLater)
                    Button(morning ? "Faire le plan" : "Faire le bilan", action: onNow).buttonStyle(LHPrimaryButtonStyle())
                }
            }
        }
        .accessibilityIdentifier(morning ? "concentration-morning-panel" : "concentration-evening-panel")
    }
}

/// A limit the member set was crossed: one fact, one way to close.
struct FocusLimitPanelView: View {
    let text: String
    var onClose: () -> Void

    var body: some View {
        FocusPanelSurface {
            HStack(spacing: 14) {
                Image(systemName: "flag").font(.system(size: 18, weight: .medium))
                    .foregroundStyle(LHTheme.secondaryText).frame(width: 26).accessibilityHidden(true)
                Text(text).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Fermer", action: onClose)
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityIdentifier("concentration-limit-panel")
    }
}

// MARK: - Evening review

/// The evening review: each item gets an answer, then tomorrow's first step and a note.
@MainActor struct ConcentrationReviewSheet: View {
    enum Choice: Hashable { case unset, done, partly, notDone, tomorrow }

    @ObservedObject var controller: ConcentrationController
    let plan: FocusPlan
    var onClose: () -> Void
    @State private var choices: [UUID: Choice]
    @State private var tomorrowFirst: String
    @State private var note: String
    @State private var error: String?

    init(controller: ConcentrationController, plan: FocusPlan, review: FocusReview?, onClose: @escaping () -> Void) {
        self.controller = controller
        self.plan = plan
        self.onClose = onClose
        var initial: [UUID: Choice] = [:]
        for item in plan.items {
            if let answer = review?.items.first(where: { $0.id == item.id }) {
                switch (answer.outcome, answer.toDay) {
                case (_, .some): initial[item.id] = .tomorrow
                case (.done?, _): initial[item.id] = .done
                case (.partly?, _): initial[item.id] = .partly
                case (.notDone?, _): initial[item.id] = .notDone
                default: initial[item.id] = .unset
                }
            } else {
                initial[item.id] = item.status == .done ? .done : item.status == .moved ? .tomorrow : .unset
            }
        }
        _choices = State(initialValue: initial)
        _tomorrowFirst = State(initialValue: review?.tomorrowFirst ?? "")
        _note = State(initialValue: review?.note ?? "")
    }

    private var items: [FocusPlanItem] { plan.items.filter { $0.status != .dropped } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bilan du soir").font(LHTheme.sheetTitleFont).tracking(-0.4)
                Text("Ce qui passe à demain est copié dans le plan de demain.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
            }
            if items.isEmpty {
                Text("Le plan du jour est vide.").foregroundStyle(LHTheme.secondaryText)
            } else {
                LHCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            HStack(spacing: 12) {
                                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                Spacer(minLength: 12)
                                GoalongSegmentedControl("Résultat de \(item.title)",
                                                        selection: Binding(get: { choices[item.id] ?? .unset }, set: { choices[item.id] = $0 }),
                                                        options: [.done, .partly, .notDone, .tomorrow]) {
                                    switch $0 {
                                    case .done: return "Fait"
                                    case .partly: return "En partie"
                                    case .notDone: return "Pas fait"
                                    case .tomorrow: return "Demain"
                                    default: return ""
                                    }
                                }
                                .fixedSize()
                            }
                            .padding(.horizontal, LHTheme.cardInset).padding(.vertical, 8).frame(minHeight: 52)
                            if item.id != items.last?.id { GoalongRowDivider(inset: LHTheme.cardInset) }
                        }
                    }
                }
            }
            GoalongFormField(title: "Demain, je commence par") {
                TextField("La première chose à faire demain", text: $tomorrowFirst)
                    .textFieldStyle(GoalongFieldStyle())
                    .accessibilityIdentifier("concentration-tomorrow-first")
            }
            GoalongFormField(title: "Note", detail: "Facultative, jusqu’à 500 caractères.") {
                GoalongTextArea(text: $note, placeholder: "Ce que vous voulez garder de la journée", minHeight: 64)
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(LHTheme.warning)
            }
            HStack {
                Spacer()
                Button("Annuler", action: onClose).keyboardShortcut(.cancelAction)
                Button("Enregistrer le bilan", action: save).buttonStyle(LHPrimaryButtonStyle())
                    .accessibilityIdentifier("concentration-save-review")
            }
        }
        .padding(28).frame(width: 640)
        .background(LHTheme.pageBackground)
    }

    private func save() {
        let tomorrow = BlockingController.dayKey(Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        let reviewItems: [FocusReview.Item] = items.compactMap { item in
            switch choices[item.id] ?? .unset {
            case .unset: return nil
            case .done: return .init(id: item.id, outcome: .done, toDay: nil)
            case .partly: return .init(id: item.id, outcome: .partly, toDay: nil)
            case .notDone: return .init(id: item.id, outcome: .notDone, toDay: nil)
            case .tomorrow:
                // Already moved by the plan menu: the review keeps its target day.
                return .init(id: item.id, outcome: nil, toDay: item.status == .moved ? item.toDay ?? tomorrow : tomorrow)
            }
        }
        let first = tomorrowFirst.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let review = FocusReview(day: plan.day, items: reviewItems,
                                 tomorrowFirst: first.isEmpty ? nil : String(first.prefix(140)),
                                 note: text.isEmpty ? nil : String(text.prefix(500)))
        do { try controller.setReview(review); onClose() } catch { self.error = FocusUIError.message(error) }
    }
}

// MARK: - Activity

/// A crossed limit, as a mark in Activity for the day shown.
@MainActor struct ConcentrationActivityMarks: View {
    var day: Date
    @ObservedObject private var runtime = ConcentrationRuntime.shared

    var body: some View {
        if let controller = runtime.controller {
            let marks = controller.limitMarks.filter { Calendar.current.isDate($0.at, inSameDayAs: day) }
            if !marks.isEmpty {
                GoalongNote(marks.map { line($0, settings: controller.settings) }.joined(separator: "\n"), symbol: "flag")
                    .accessibilityIdentifier("concentration-activity-marks")
            }
        }
    }

    private func line(_ mark: FocusLimitMark, settings: FocusSettings) -> String {
        let at = BlockingFormat.time(mark.at)
        let what = mark.usesActiveTime ? "d’activité (sans définition du travail)" : "de travail"
        switch mark.kind {
        case "weekly": return "Limite de la semaine atteinte à \(at) : \(settings.limits.weeklyHours.map { "\($0) h " } ?? "")\(what)."
        case "daily": return "Limite du jour atteinte à \(at) : \(settings.limits.dailyHours.map { "\($0) h " } ?? "")\(what)."
        default: return "Fin de journée à \(at)."
        }
    }
}
#endif
