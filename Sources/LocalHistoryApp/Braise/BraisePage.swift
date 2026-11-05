#if os(macOS)
import LocalHistoryCore
import AppKit
import BraiseCore
import ServiceManagement
import SwiftUI

@MainActor struct BraisePage: View {
    /// Each range switch names its range: two ranges at the same hours differ by their days (R-93).
    static func rangeSwitchLabel(_ range: BlockProgramRange) -> String {
        "Activer la plage \(BlockingFormat.range(range)), \(BlockingFormat.weekdays(range.weekdays))"
    }
    var showsTitle = true

    @ObservedObject private var runtime = BraiseRuntime.shared
    var body: some View {
        if let controller = runtime.controller { BraisePageContent(controller: controller, showsTitle: showsTitle) }
        else { BraiseUnavailableView(showsTitle: showsTitle, error: runtime.error, onRetry: { runtime.retry() },
                                     onTurnOn: { runtime.setRedScreen(true) }, onPrepare: { runtime.ensureController() }) }
    }
}

/// Never used yet (nothing runs), or a start that failed: the failure always offers a new attempt.
@MainActor struct BraiseUnavailableView: View {
    var showsTitle = true
    let error: String?
    let onRetry: () -> Void
    let onTurnOn: () -> Void
    let onPrepare: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if showsTitle { Text("Écran rouge").goalongPageTitle() }
            if let error {
                GoalongEmptyState(title: "L’écran rouge n’a pas pu démarrer", kind: .unavailable, message: error) {
                    Button("Réessayer", action: onRetry).buttonStyle(LHPrimaryButtonStyle())
                }
            } else {
                GoalongEmptyState(title: "Écran rouge éteint", kind: .empty,
                                  message: "Le filtre rouge du soir. Il s’allume aussi depuis le menu Goalong, dans la barre des menus.") {
                    Button("Allumer l’écran rouge", action: onTurnOn).buttonStyle(LHPrimaryButtonStyle())
                        .accessibilityIdentifier("braise-enable")
                    Button("Régler les plages", action: onPrepare).buttonStyle(LHSecondaryButtonStyle())
                }
            }
        }
        .padding(LHTheme.pageInset).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LHTheme.pageBackground)
    }
}

/// One range being edited (T-048 B2): the blocking range plus its red intensity.
struct RedScreenRangeDraft: Identifiable, Equatable {
    var range: BlockProgramRange
    var intensity: Double
    var enabled: Bool
    var existed: Bool
    var id: UUID { range.id }
}

/// Garde-fous › Écran rouge: the manual red, « Suivre mes horaires » and the ranges.
/// A range has the blocking model and safeties (docs/BLOCKING.md), plus an intensity.
@MainActor struct BraisePageContent: View {
    @ObservedObject var controller: BraiseController
    var showsTitle = true
    @State private var editing: RedScreenRangeDraft?
    @State private var challenge: String?
    @State private var askingPassword = false
    @State private var rowError: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LHTheme.sectionSpacing) {
                if showsTitle {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Écran rouge").goalongPageTitle()
                        Text("Le filtre rouge, à vos plages.").foregroundStyle(LHTheme.secondaryText)
                    }
                }
                statusBlock
                if let notice = controller.recoveryNotice { GoalongNote(notice, tone: .warning).accessibilityIdentifier("braise-recovery") }
                if let error = controller.errorMessage { GoalongNote(error, tone: .warning).accessibilityIdentifier("braise-error") }
                controlsCard
                rangesSection
                safetyGroup
            }
            .font(.system(size: 13)).frame(maxWidth: LHTheme.readableWidth, alignment: .leading)
            .padding(.horizontal, LHTheme.pageInset).padding(.top, showsTitle ? 28 : 16).padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
        .accessibilityIdentifier("braise-page")
        .sheet(item: $editing) { RedScreenRangeEditor(controller: controller, initial: $0).goalongControls() }
        .sheet(item: Binding(get: { challenge.map(RedScreenChallenge.init) }, set: { challenge = $0?.text })) { item in
            BlockingTypingChallengeSheet(text: item.text, onSubmit: { typed in
                if controller.stopActiveRanges(typed: typed, challenge: item.text) == .stopped { challenge = nil }
            }, onCancel: { challenge = nil; controller.cancelStop() }).goalongControls()
        }
        .sheet(isPresented: $askingPassword) {
            RedScreenPasswordSheet(controller: controller) { askingPassword = false }.goalongControls()
        }
        .onChange(of: controller.pendingStop) { if $0 != nil { beginStop() } }
        .onAppearWhenShown { if controller.pendingStop != nil { beginStop() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.refreshLoginStatus() }
    }

    private var statusBlock: some View {
        Group {
                VStack(alignment: .leading, spacing: 10) {
                    Text(controller.stateLabel).font(LHTheme.sectionTitleFont)
                    Text(controller.nextEvent).foregroundStyle(LHTheme.secondaryText)
                    // One main action per state: « Reprendre » while paused, « Pause 15 min » while the filter is on.
                    HStack(spacing: 8) {
                        if controller.isPaused {
                            Button("Reprendre") { controller.resume() }.buttonStyle(LHPrimaryButtonStyle())
                        } else if controller.active {
                            Button("Pause 15 min") { controller.pause() }.buttonStyle(LHPrimaryButtonStyle())
                        }
                        Button("Rétablir les couleurs") { controller.emergencyOff() }.buttonStyle(LHSecondaryButtonStyle())
                            .accessibilityIdentifier("braise-emergency-off")
                    }
                }
                if let window = controller.protectedWindow { protectedNote(window) }
                if controller.pendingStop != nil, controller.protectedWindow != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        GoalongNote("Cette commande attend l’arrêt de la plage en cours.")
                        HStack(spacing: 8) {
                            Button("Arrêter la plage…") { beginStop() }.buttonStyle(LHSecondaryButtonStyle())
                            Button("Annuler") { controller.cancelStop() }.buttonStyle(LHQuietButtonStyle())
                        }
                    }.accessibilityIdentifier("braise-pending-stop")
                }
        }
    }
    private var controlsCard: some View {
        Group {
                LHCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Toggle("Écran rouge manuel", isOn: Binding(get: { controller.preferences.mode == .on }, set: { controller.setManual($0) }))
                            .toggleStyle(.goalongSwitchInline).accessibilityIdentifier("braise-manual")
                        Toggle("Suivre mes horaires", isOn: Binding(get: { controller.ranges.follows }, set: { controller.setFollows($0) }))
                            .toggleStyle(.goalongSwitchInline).accessibilityIdentifier("braise-follows")
                        slider("Intensité du rouge", value: Binding(get: { controller.active ? controller.appliedIntensity : controller.preferences.intensity },
                                                                    set: { controller.slideIntensity($0) }), range: 0...1)
                        if let notice = controller.sliderNotice {
                            Text(notice).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                .accessibilityIdentifier("braise-slider-notice")
                        }
                        slider("Luminosité du filtre", value: Binding(get: { controller.preferences.brightness }, set: { n in controller.update { $0.brightness = n } }), range: 0.2...1)
                        Text("Le rouge manuel et les plages se cumulent : le plus fort l’emporte. La luminosité est un confort : elle ne touche pas aux plages.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                }
        }
    }
    private var rangesSection: some View {
        Group {
                GoalongSection(title: "Plages protégées", subtitle: "Une plage qui passe minuit compte pour le jour où elle commence.") {
                    VStack(alignment: .leading, spacing: 12) {
                        if controller.ranges.program.ranges.isEmpty {
                            GoalongEmptyState(title: "Aucune plage", kind: .empty, message: "Ajoutez une plage, puis cochez « Suivre mes horaires ».")
                        }
                        ForEach(controller.ranges.program.ranges) { range in rangeRow(range) }
                        if let rowError { GoalongNote(rowError, tone: .warning) }
                        Button("Ajouter une plage") {
                            editing = RedScreenRangeDraft(range: BlockProgramRange(weekdays: Set(1...7), startMinute: 22 * 60, endMinute: 7 * 60),
                                                          intensity: controller.preferences.intensity, enabled: true, existed: false)
                        }
                        .buttonStyle(LHSecondaryButtonStyle()).disabled(controller.ranges.program.ranges.count >= RedScreenProgram.maximumRanges)
                        .accessibilityIdentifier("braise-add-rule")
                    }
                }
        }
    }
    private var safetyGroup: some View {
        Group {
                GoalongDisclosureGroup("Réglages et sécurité") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Retour aux couleurs naturelles : ⌃ ⌥ ⌘ R")
                        Text(controller.shortcutAvailable ? "Raccourci de secours global. Pendant une plage protégée, il passe par l’arrêt de la plage, comme un blocage." : "Raccourci indisponible ou déjà utilisé. Utilisez Rétablir les couleurs, ici ou dans le menu Goalong.")
                            .foregroundStyle(LHTheme.secondaryText)
                        Toggle("Lancer Goalong à l’ouverture de session", isOn: Binding(get: { controller.loginEnabled || controller.loginApprovalRequired }, set: { try? controller.setLogin($0) }))
                            .toggleStyle(.goalongSwitchInline)
                        Text("Ce réglage concerne toute l’app Goalong. L’écran rouge suit ses plages tant que Goalong est ouverte.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                        if controller.loginApprovalRequired {
                            Button("Ouvrir Réglages Système…") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(LHQuietButtonStyle())
                        }
                        Text("\(FrenchCount.count(controller.displayCount, "écran", "écrans")). Le filtre est recalculé au réveil. Il ne réveille pas le Mac.").foregroundStyle(LHTheme.secondaryText)
                        Text("Aucun réseau ni nouvel accès. Une panne technique rend toujours les couleurs tout de suite, même pendant une plage protégée. Les couleurs sont restaurées à l’arrêt du rouge, à la fermeture de Goalong ou par un gardien après un crash. Le HDR et les autres filtres peuvent modifier le résultat ; zéro lumière bleue physiquement émise n’est pas garanti.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }.fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                }
                .collapsedSummary("Secours : ⌃ ⌥ ⌘ R")
        }
    }

    /// The stop of an active block: « Difficile » = retype a text, « Mot de passe » = the blocking password.
    private func beginStop() {
        guard let window = controller.protectedWindow else {
            if controller.pendingStop != nil { _ = controller.stopActiveRanges() }
            return
        }
        switch window.lock {
        case .typing: if challenge == nil { challenge = BlockingController.newTypingChallenge() }
        case .password: askingPassword = true
        case .locked, .free: break
        }
    }

    private func protectedNote(_ window: RedScreenWindow) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text("Plage protégée jusqu’à \(GoalongUIFormat.time(window.end)), encore \(BlockingFormat.remaining(window.end.timeIntervalSince(context.date)))")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                BlockingLockExplainer(lock: window.lock)
                if window.lock != .locked {
                    Button(window.lock == .password ? "Arrêter avec le mot de passe…" : "Arrêter la plage…") { beginStop() }
                        .buttonStyle(LHSecondaryButtonStyle()).accessibilityIdentifier("braise-stop-range")
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("braise-protected")
    }

    private func rangeRow(_ range: BlockProgramRange) -> some View {
        let enabled = !controller.ranges.disabled.contains(range.id)
        let intensity = controller.ranges.intensity(of: range.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    editing = RedScreenRangeDraft(range: range, intensity: intensity, enabled: enabled, existed: true)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(BlockingFormat.range(range)).monospacedDigit()
                        Text("\(BlockingFormat.weekdays(range.weekdays)) · rouge à \(GoalongUIFormat.percent(intensity * 100)) · \(range.effectiveLock.title)")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(LHQuietButtonStyle())
                    .accessibilityLabel("Modifier la plage \(BlockingFormat.range(range)), \(BlockingFormat.weekdays(range.weekdays))")
                Toggle("Activer la plage", isOn: Binding(get: { enabled }, set: { on in
                    do { try controller.setRangeEnabled(range.id, on); rowError = nil } catch { rowError = error.localizedDescription }
                })).toggleStyle(.goalongSwitchOnly).fixedSize().accessibilityLabel(BraisePage.rangeSwitchLabel(range))
            }
            // Aligned on the text of the rows (DESIGN §7): these rows have no icon column.
            GoalongRowDivider(inset: 0)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title); Spacer(); Text(GoalongUIFormat.percent(value.wrappedValue * 100)).monospacedDigit().foregroundStyle(LHTheme.secondaryText) }
            Slider(value: value, in: range).accessibilityLabel(title).accessibilityValue("\(Int(value.wrappedValue * 100)) pour cent")
        }
    }
}

private struct RedScreenChallenge: Identifiable {
    let text: String
    var id: String { text }
}

/// The blocking password, to stop a « Mot de passe » range. Same password, attempts and waits as Blocages.
@MainActor struct RedScreenPasswordSheet: View {
    @ObservedObject var controller: BraiseController
    var onClose: () -> Void
    @State private var password = ""
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Arrêter la plage").font(LHTheme.sheetTitleFont).tracking(-0.4)
            Text("Entrez le mot de passe de blocage. La commande demandée s’applique ensuite.").foregroundStyle(LHTheme.secondaryText)
            SecureField("Mot de passe", text: $password).textFieldStyle(.roundedBorder).onSubmit(submit)
                .accessibilityIdentifier("braise-stop-password")
            if let message { Text(message).foregroundStyle(LHTheme.warning).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Annuler") { controller.cancelStop(); onClose() }.buttonStyle(LHSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Arrêter", action: submit).buttonStyle(LHPrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(password.isEmpty)
            }
        }.font(.system(size: 13)).padding(28).frame(width: 460)
            .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text)
    }
    private func submit() {
        let result = controller.stopActiveRanges(password: password)
        password = ""
        switch result {
        case .stopped: onClose()
        case .wrongText: message = "Texte différent."
        case .locked(let until): message = BraiseController.lockedText(until: until, now: GoalongToday.now)
        case .password(let answer): message = Self.text(answer)
        }
    }
    static func text(_ answer: BlockingPasswordResult) -> String {
        switch answer {
        case .ok: return ""
        case .wrong(let remaining): return "Mot de passe incorrect. Encore \(FrenchCount.count(remaining, "essai", "essais")) avant une attente."
        case .wait(let until): return "Trop d’essais. Réessayez à \(GoalongUIFormat.time(until))."
        case .refused(let reason): return reason
        }
    }
}

/// Adds or changes a range: the blocking range editor's parts (days, hours, stop rule) plus the intensity.
@MainActor struct RedScreenRangeEditor: View {
    @ObservedObject var controller: BraiseController
    @ObservedObject private var blocking = BlockingRuntime.shared
    @State private var draft: RedScreenRangeDraft
    @State private var error: String?
    @State private var unreadableFields: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    init(controller: BraiseController, initial: RedScreenRangeDraft) {
        self.controller = controller; _draft = State(initialValue: initial)
    }
    private var lock: Binding<BlockLock> { Binding(get: { draft.range.effectiveLock }, set: { draft.range.lock = $0 == .free ? nil : $0 }) }
    private var startMinute: Binding<Int> { Binding(get: { draft.range.startMinute }, set: { draft.range.startMinute = $0 }) }
    private var endMinute: Binding<Int> { Binding(get: { draft.range.endMinute % 1_440 }, set: { draft.range.endMinute = $0 == 0 ? 1_440 : $0 }) }
    private var next: RedScreenProgram {
        var value = controller.ranges
        if let i = value.program.ranges.firstIndex(where: { $0.id == draft.id }) { value.program.ranges[i] = draft.range } else { value.program.ranges.append(draft.range) }
        value.intensities[draft.id] = draft.intensity
        if draft.enabled { value.disabled.remove(draft.id) } else { value.disabled.insert(draft.id) }
        return value
    }
    var body: some View {
        let refusal = controller.refusal(for: next)
        VStack(alignment: .leading, spacing: 20) {
            Text(draft.existed ? "Modifier la plage" : "Ajouter une plage").font(LHTheme.sheetTitleFont).tracking(-0.4)
            Text("Jours concernés").foregroundStyle(LHTheme.secondaryText)
            HStack(spacing: 10) {
                ForEach(1...7, id: \.self) { day in
                    Toggle(BlockingFormat.weekdayShort[day - 1], isOn: Binding(get: { draft.range.weekdays.contains(day) }, set: { on in
                        if on { draft.range.weekdays.insert(day) } else { draft.range.weekdays.remove(day) }
                    })).toggleStyle(.goalongCheckbox)
                }
            }
            // Shortcuts as the kit's segmented control: the matching preset shows selected, none for any other set of days.
            GoalongSegmentedControl("Raccourcis de jours", selection: Binding(get: { BraiseDayPreset(weekdays: draft.range.weekdays) },
                                                                             set: { if let preset = $0 { draft.range.weekdays = preset.weekdays } }),
                                    options: BraiseDayPreset.allCases.map(Optional.some), title: { $0?.title ?? "" })
            HStack(spacing: 24) { time("Début", minute: startMinute); time("Fin", minute: endMinute) }
            Text(!RedScreenProgram.isUsable(draft.range) ? "Choisissez au moins un jour et deux heures différentes." : draft.range.crossesMidnight ? "La plage finit le lendemain à \(BlockingFormat.rangeEnd(draft.range.endMinute))." : "La plage commence et se termine le même jour.")
                .foregroundStyle(LHTheme.secondaryText)
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("Rouge à"); Spacer(); Text(GoalongUIFormat.percent(draft.intensity * 100)).monospacedDigit().foregroundStyle(LHTheme.secondaryText) }
                Slider(value: $draft.intensity, in: 0...1).accessibilityLabel("Intensité de la plage")
                    .accessibilityValue("\(Int(draft.intensity * 100)) pour cent")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Arrêt pendant la plage").foregroundStyle(LHTheme.secondaryText)
                if let lists = blocking.controller {
                    BlockingLockPicker(controller: lists, lock: lock)
                } else {
                    // Without Blocages there is no password: « Mot de passe » is not offered.
                    GoalongSegmentedControl("Arrêt", selection: lock, options: BlockLock.ordered.filter { $0 != .password }) { $0.title }
                    BlockingLockExplainer(lock: draft.range.effectiveLock)
                }
            }
            if let message = refusal ?? error { Text(message).foregroundStyle(LHTheme.warning).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if draft.existed {
                    Button("Supprimer", role: .destructive) {
                        do { try controller.deleteRange(draft.id); dismiss() } catch { self.error = error.localizedDescription }
                    }.buttonStyle(LHQuietButtonStyle())
                }
                Spacer()
                Button("Annuler") { dismiss() }.buttonStyle(LHSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    do { try controller.saveRange(draft.range, intensity: draft.intensity, enabled: draft.enabled); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(LHPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(!RedScreenProgram.isUsable(draft.range) || !unreadableFields.isEmpty || refusal != nil)
            }
        }.font(.system(size: 13)).padding(28).frame(width: 590)
            .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text)
    }
    private func time(_ title: String, minute: Binding<Int>) -> some View {
        HStack(spacing: 10) {
            Text(title)
            ScheduleTimeField(title: title, minute: minute, onValidity: { valid in
                if valid { unreadableFields.remove(title) } else { unreadableFields.insert(title) }
            })
        }
    }
}

/// Day shortcuts of the range editor (ISO weekdays, Monday = 1).
enum BraiseDayPreset: CaseIterable, Hashable {
    case everyDay, weekdays, weekend
    var weekdays: Set<Int> {
        switch self {
        case .everyDay: return Set(1...7)
        case .weekdays: return Set(1...5)
        case .weekend: return [6, 7]
        }
    }
    var title: String {
        switch self {
        case .everyDay: return "Tous les jours"
        case .weekdays: return "Semaine"
        case .weekend: return "Week-end"
        }
    }
    init?(weekdays: Set<Int>) {
        guard let match = Self.allCases.first(where: { $0.weekdays == weekdays }) else { return nil }
        self = match
    }
}

/// Editable "HH:mm" field with a 5-minute stepper. Typing "7", "0730" or "7:30" works.
/// The binding follows the text as soon as it parses, without reformatting it while typing.
/// Text that does not parse reports `onValidity(false)` (the sheet disables Save) and reverts on commit.
struct ScheduleTimeField: View {
    let title: String
    @Binding var minute: Int
    var onValidity: (Bool) -> Void = { _ in }
    @State private var text = ""
    @FocusState private var focused: Bool

    static func format(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    /// Minutes since midnight for "H", "HH", "HHmm", "H:mm", "H h mm"; nil when not a valid time of day.
    static func parse(_ raw: String) -> Int? {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        let parts = t.split(whereSeparator: { ":hH. ".contains($0) }).map(String.init).filter { !$0.isEmpty }
        var hour: Int?, min = 0
        if parts.count == 1, let n = Int(parts[0]), parts[0].allSatisfy(\.isNumber) {
            if parts[0].count <= 2 { hour = n }
            else if parts[0].count <= 4 { hour = n / 100; min = n % 100 }
        } else if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), parts[1].count <= 2 { hour = h; min = m }
        guard let hour, (0...23).contains(hour), (0...59).contains(min) else { return nil }
        return hour * 60 + min
    }

    /// Typed text -> the minute to hold. `nil` keeps the current minute (text does not parse).
    static func minute(typing text: String, current: Int) -> Int? {
        guard let parsed = parse(text) else { return nil }
        return parsed == current ? nil : parsed
    }

    private func typed(_ newText: String) {
        onValidity(Self.parse(newText) != nil)
        if let parsed = Self.minute(typing: newText, current: minute) { minute = parsed }
    }

    private func commit() {
        if let parsed = Self.parse(text) { minute = parsed }
        text = Self.format(minute)
        onValidity(true)
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("HH:mm", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 13).monospacedDigit())
                .frame(width: 52)
                .focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(LHTheme.cardBackground))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.accentColor : LHTheme.secondaryText.opacity(0.3)))
                .accessibilityLabel(title)
                .onSubmit(commit)
                .onChange(of: focused) { if !$0 { commit() } }
            Stepper(title, value: Binding(get: { minute }, set: { minute = (($0 % 1440) + 1440) % 1440 }), in: -5...1445, step: 5)
                .labelsHidden()
        }
        .onAppearWhenShown { text = Self.format(minute) }
        .onChange(of: text) { typed($0) }
        .onChange(of: minute) { if Self.parse(text) != $0 { text = Self.format($0); onValidity(true) } }
    }
}
#endif
