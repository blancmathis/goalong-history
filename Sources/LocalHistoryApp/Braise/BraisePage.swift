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
    /// Hardware brightness the range holds (T-048 D2), nil = none.
    var brightness: Double? = nil
    var id: UUID { range.id }
}

/// The old page Garde-fous › Écran rouge: the manual red and the ranges. The page « Blocages » shows `live` and `safety`.
/// A range has the blocking model and safeties (docs/BLOCKING.md), plus an intensity.
@MainActor struct BraisePageContent: View {
    /// The whole page, or one part of it set in the page « Blocages »: `live` (what is on now, with its stops),
    /// `safety` (shortcut, login, privacy). The manual red lives in the menu bar (T-050 point 10).
    /// `listener` shows nothing: it opens the stop sheet a command asks for (menu, shortcut, a switch of `manual`).
    /// One listener per window: two would open two sheets for one stop.
    enum Part { case page, live, safety, listener }

    @ObservedObject var controller: BraiseController
    var showsTitle = true
    var part: Part = .page
    @State private var editing: RedScreenRangeDraft?
    @State private var challenge: String?
    @State private var askingPassword = false
    @State private var rowError: String?
    @State private var brightnessChallenge: String?
    @State private var askingBrightnessPassword = false
    @State private var protectLock: BlockLock = .typing
    @State private var protectUntil = 7 * 60
    @State private var brightnessError: String?

    /// Whether `live` has something to show (the page « Blocages » says « Rien n’est bloqué » otherwise).
    static func hasLive(_ controller: BraiseController) -> Bool {
        controller.active || controller.isPaused || controller.protectedWindow != nil || controller.pendingStop != nil
            || controller.recoveryNotice != nil || controller.errorMessage != nil || controller.brightnessLock != nil
    }

    var body: some View {
        switch part {
        case .page:
            stopSheets(page, listens: true)
                .sheet(item: $editing) { RedScreenRangeEditor(controller: controller, initial: $0).goalongControls() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.refreshLoginStatus() }
        case .live:
            stopSheets(live, listens: false)
        case .safety:
            safetyDetails.font(.system(size: 13))
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.refreshLoginStatus() }
        case .listener:
            stopSheets(Color.clear.frame(width: 0, height: 0).accessibilityHidden(true), listens: true)
        }
    }

    private var page: some View {
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
                brightnessSection
                rangesSection
                safetyGroup
            }
            .font(.system(size: 13)).frame(maxWidth: LHTheme.readableWidth, alignment: .leading)
            .padding(.horizontal, LHTheme.pageInset).padding(.top, showsTitle ? 28 : 16).padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text).tint(LHTheme.accent)
        .accessibilityIdentifier("braise-page")
    }

    /// « En cours » of the page « Blocages »: the red on now and a held brightness, each with its stop.
    private var live: some View {
        VStack(alignment: .leading, spacing: 14) {
            if controller.active || controller.isPaused || controller.protectedWindow != nil || controller.pendingStop != nil {
                statusBlock
            }
            if let notice = controller.recoveryNotice { GoalongNote(notice, tone: .warning).accessibilityIdentifier("braise-recovery") }
            if let error = controller.errorMessage { GoalongNote(error, tone: .warning).accessibilityIdentifier("braise-error") }
            if let lock = controller.brightnessLock {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Luminosité bloquée à \(GoalongUIFormat.percent(lock.level * 100))").font(.system(size: 14, weight: .semibold))
                    if let held = controller.brightnessProtection {
                        brightnessProtectedNote(held)
                    } else {
                        Button("Débloquer la luminosité") { setBrightnessLock(false) }.buttonStyle(LHSecondaryButtonStyle())
                            .accessibilityIdentifier("braise-live-brightness-off")
                    }
                    if let brightnessError { GoalongNote(brightnessError, tone: .warning) }
                }
            }
        }
        .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain).accessibilityIdentifier("braise-live")
    }

    /// The four stop sheets of a protected range or brightness lock. `listens` also opens them when a command
    /// elsewhere waits for the stop (`pendingStop`, `pendingBrightness`).
    private func stopSheets<Body: View>(_ view: Body, listens: Bool) -> some View {
        view
        .sheet(item: Binding(get: { challenge.map(RedScreenChallenge.init) }, set: { challenge = $0?.text })) { item in
            BlockingTypingChallengeSheet(text: item.text, onSubmit: { typed in
                if controller.stopActiveRanges(typed: typed, challenge: item.text) == .stopped { challenge = nil }
            }, onCancel: { challenge = nil; controller.cancelStop() }).goalongControls()
        }
        .sheet(isPresented: $askingPassword) {
            RedScreenPasswordSheet(controller: controller) { askingPassword = false }.goalongControls()
        }
        .sheet(item: Binding(get: { brightnessChallenge.map(RedScreenChallenge.init) }, set: { brightnessChallenge = $0?.text })) { item in
            BlockingTypingChallengeSheet(text: item.text, onSubmit: { typed in
                if controller.stopBrightnessLock(typed: typed, challenge: item.text) == .stopped { brightnessChallenge = nil }
            }, onCancel: { brightnessChallenge = nil; controller.cancelBrightnessStop() }).goalongControls()
        }
        .sheet(isPresented: $askingBrightnessPassword) {
            RedScreenPasswordSheet(controller: controller, title: "Arrêter le verrou de luminosité",
                                   stop: { controller.stopBrightnessLock(password: $0) },
                                   cancel: { controller.cancelBrightnessStop() }) { askingBrightnessPassword = false }.goalongControls()
        }
        .onChange(of: controller.pendingStop) { if listens, $0 != nil { beginStop() } }
        .onChange(of: controller.pendingBrightness) { if listens, $0 != nil { beginBrightnessStop() } }
        .onAppearWhenShown {
            guard listens else { return }
            if controller.pendingStop != nil { beginStop() }
            if controller.pendingBrightness != nil { beginBrightnessStop() }
        }
    }

    /// On the page « Blocages » the block stands alone, so its title names the red screen.
    private var statusTitle: String {
        guard part != .page else { return controller.stateLabel }
        return controller.isPaused ? "Écran rouge en pause" : controller.active ? "Écran rouge actif" : controller.stateLabel
    }

    private var statusBlock: some View {
        Group {
                VStack(alignment: .leading, spacing: 10) {
                    Text(statusTitle).font(part == .page ? LHTheme.sectionTitleFont : .system(size: 14, weight: .semibold))
                    Text(controller.nextEvent).foregroundStyle(LHTheme.secondaryText)
                    // One main action per state: « Reprendre » while paused, « Pause 15 min » while the filter is on.
                    HStack(spacing: 8) {
                        if controller.isPaused {
                            if part == .page { Button("Reprendre") { controller.resume() }.buttonStyle(LHPrimaryButtonStyle()) }
                            else { Button("Reprendre") { controller.resume() }.buttonStyle(LHSecondaryButtonStyle()) }
                        } else if controller.active {
                            if part == .page { Button("Pause 15 min") { controller.pause() }.buttonStyle(LHPrimaryButtonStyle()) }
                            else { Button("Pause 15 min") { controller.pause() }.buttonStyle(LHSecondaryButtonStyle()) }
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
                            GoalongEmptyState(title: "Aucune plage", kind: .empty, message: "Ajoutez une plage : elle suit ses horaires.")
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
        GoalongDisclosureGroup("Réglages et sécurité") { safetyDetails.padding(.top, 12) }
            .collapsedSummary("Secours : ⌃ ⌥ ⌘ R")
    }
    private var safetyDetails: some View {
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
        }.fixedSize(horizontal: false, vertical: true)
    }

    /// « Verrou de luminosité » (T-048 D2): the hardware brightness held at one level; the same stop rules as a range.
    private var brightnessSection: some View {
        GoalongSection(title: "Verrou de luminosité", subtitle: "Les touches de luminosité, le Centre de contrôle et Réglages sont ramenés au niveau choisi.") {
            LHCard {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Verrouiller la luminosité", isOn: Binding(get: { controller.brightnessLock != nil }, set: { setBrightnessLock($0) }))
                        .toggleStyle(.goalongSwitchInline).accessibilityIdentifier("braise-brightness-lock")
                        .disabled(controller.brightnessLock == nil && !controller.canControlBrightness)
                    if let lock = controller.brightnessLock {
                        slider("Luminosité verrouillée", value: Binding(get: { lock.level }, set: { controller.slideBrightnessLock($0) }),
                               range: BrightnessLockRules.levelRange)
                        if let notice = controller.brightnessNotice {
                            Text(notice).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                .accessibilityIdentifier("braise-brightness-notice")
                        }
                        if let held = controller.brightnessProtection { brightnessProtectedNote(held) } else { brightnessProtectRow(lock) }
                        if controller.pendingBrightness != nil, controller.brightnessProtection != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                GoalongNote("Ce changement attend l’arrêt de la protection du verrou.")
                                HStack(spacing: 8) {
                                    Button("Arrêter la protection…") { beginBrightnessStop() }.buttonStyle(LHSecondaryButtonStyle())
                                    Button("Annuler") { controller.cancelBrightnessStop() }.buttonStyle(LHQuietButtonStyle())
                                }
                            }.accessibilityIdentifier("braise-brightness-pending")
                        }
                    }
                    if let target = controller.brightnessTarget, target < (controller.brightnessLock?.level ?? 2) - BrightnessLockRules.tolerance {
                        Text("Une plage en cours tient la luminosité à \(GoalongUIFormat.percent(target * 100)) au plus.")
                            .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    }
                    if let brightnessError { GoalongNote(brightnessError, tone: .warning) }
                    brightnessDisplaysNote
                }
            }
        }.accessibilityIdentifier("braise-brightness")
    }

    private func brightnessProtectRow(_ lock: BrightnessLockState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Protéger l’arrêt (et toute hausse)").foregroundStyle(LHTheme.secondaryText)
            if let lists = BlockingRuntime.shared.controller {
                BlockingLockPicker(controller: lists, lock: $protectLock, minimum: .typing)
            } else {
                GoalongSegmentedControl("Arrêt", selection: $protectLock, options: [.typing, .locked]) { $0.title }
                BlockingLockExplainer(lock: protectLock)
            }
            HStack(spacing: 10) {
                Text("Jusqu’à")
                ScheduleTimeField(title: "Fin de la protection", minute: $protectUntil)
                Button("Protéger") {
                    let end = BrightnessLockRules.nextOccurrence(minute: protectUntil, after: GoalongToday.now, calendar: .autoupdatingCurrent)
                    var next = lock; next.lock = protectLock; next.end = end
                    do {
                        try controller.setBrightnessLock(next); brightnessError = nil
                        if BlockingRuntime.shared.guardNeedsConsent { BlockingRuntime.shared.recordGuardConsent() }
                    } catch { brightnessError = error.localizedDescription }
                }.buttonStyle(LHSecondaryButtonStyle()).accessibilityIdentifier("braise-brightness-protect")
            }
            if BlockingRuntime.shared.guardNeedsConsent {
                Text(GuardConsent.text).font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func brightnessProtectedNote(_ held: (lock: BlockLock, end: Date)) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                Text("Verrou protégé jusqu’à \(GoalongUIFormat.time(held.end)), encore \(BlockingFormat.remaining(held.end.timeIntervalSince(controller.now)))")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                BlockingLockExplainer(lock: held.lock)
                if held.lock != .locked {
                    Button(held.lock == .password ? "Arrêter avec le mot de passe…" : "Arrêter la protection…") {
                        _ = try? controller.setBrightnessLock(nil)
                    }.buttonStyle(LHSecondaryButtonStyle()).accessibilityIdentifier("braise-brightness-stop")
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("braise-brightness-protected")
    }

    /// Which screens the lock drives; an external monitor that DisplayServices cannot set is named as such.
    private var brightnessDisplaysNote: some View {
        let screens = controller.brightnessDisplays
        return VStack(alignment: .leading, spacing: 4) {
            if !controller.canControlBrightness {
                GoalongNote(screens.isEmpty ? "Goalong ne trouve aucun écran dont il peut régler la luminosité."
                            : "Goalong ne peut régler la luminosité d’aucun de ces écrans. Les écrans externes ne se règlent en général pas depuis le Mac.",
                            tone: .warning).accessibilityIdentifier("braise-brightness-unavailable")
            }
            ForEach(screens) { screen in
                Text("\(Self.screenName(screen)) : \(screen.controllable ? "tenu par le verrou" : "ne peut pas être réglé par Goalong")")
                    .font(.system(size: 12)).foregroundStyle(screen.controllable ? LHTheme.secondaryText : LHTheme.warning)
            }
            Text("La luminosité automatique est contrée aussi. Une panne de l’écran ou de macOS laisse la luminosité telle quelle.")
                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }
    static func screenName(_ screen: BrightnessDisplay) -> String {
        if screen.builtIn { return "Écran intégré" }
        let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == screen.id }?.localizedName
        return name ?? "Écran externe"
    }

    private func setBrightnessLock(_ on: Bool) {
        do {
            if on {
                let level = controller.currentHardwareBrightness() ?? 0.5
                try controller.setBrightnessLock(BrightnessLockState(level: level))
            } else { try controller.setBrightnessLock(nil) }
            brightnessError = nil
        } catch { brightnessError = error.localizedDescription }
    }

    private func beginBrightnessStop() {
        guard let held = controller.brightnessProtection else {
            if controller.pendingBrightness != nil { _ = controller.stopBrightnessLock() }
            return
        }
        switch held.lock {
        case .typing: if brightnessChallenge == nil { brightnessChallenge = BlockingController.newTypingChallenge() }
        case .password: askingBrightnessPassword = true
        case .locked, .free: break
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
        let brightness = controller.ranges.brightness(of: range.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    editing = RedScreenRangeDraft(range: range, intensity: intensity, enabled: enabled, existed: true, brightness: brightness)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(BlockingFormat.range(range)).monospacedDigit()
                        Text("\(BlockingFormat.weekdays(range.weekdays)) · rouge à \(GoalongUIFormat.percent(intensity * 100))\(brightness.map { " · luminosité \(GoalongUIFormat.percent($0 * 100))" } ?? "") · \(range.effectiveLock.title)")
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
    var title = "Arrêter la plage"
    /// The stop to run (default: the ranges in progress).
    var stop: ((String) -> RedScreenStopResult)?
    var cancel: (() -> Void)?
    var onClose: () -> Void
    @State private var password = ""
    @State private var message: String?
    @FocusState private var passwordFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(LHTheme.sheetTitleFont).tracking(-0.4)
            Text("Entrez le mot de passe de blocage. La commande demandée s’applique ensuite.").foregroundStyle(LHTheme.secondaryText)
            SecureField("Mot de passe", text: $password).textFieldStyle(.roundedBorder).onSubmit(submit)
                .focused($passwordFocused)
                .accessibilityIdentifier("braise-stop-password")
            if let message { Text(message).foregroundStyle(LHTheme.warning).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Annuler") { if let cancel { cancel() } else { controller.cancelStop() }; onClose() }.buttonStyle(LHSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Arrêter", action: submit).buttonStyle(LHPrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(password.isEmpty)
            }
        }.font(.system(size: 13)).padding(28).frame(width: 460)
            .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text)
            .onAppear { passwordFocused = true } // own layout
    }
    private func submit() {
        // Enter in an empty field: nothing is sent, no try is counted (T-063).
        guard !password.isEmpty else { message = BlockingController.emptyPasswordText; return }
        let result = stop?(password) ?? controller.stopActiveRanges(password: password)
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
    /// What the sheet opened with: a click outside asks first when the range differs from it or a time field holds unread text.
    private let initial: RedScreenRangeDraft
    init(controller: BraiseController, initial: RedScreenRangeDraft) {
        self.controller = controller; _draft = State(initialValue: initial); self.initial = initial
    }
    private var lock: Binding<BlockLock> { Binding(get: { draft.range.effectiveLock }, set: { draft.range.lock = $0 == .free ? nil : $0 }) }
    private var startMinute: Binding<Int> { Binding(get: { draft.range.startMinute }, set: { draft.range.startMinute = $0 }) }
    private var endMinute: Binding<Int> { Binding(get: { draft.range.endMinute % 1_440 }, set: { draft.range.endMinute = $0 == 0 ? 1_440 : $0 }) }
    private var next: RedScreenProgram {
        var value = controller.ranges
        if let i = value.program.ranges.firstIndex(where: { $0.id == draft.id }) { value.program.ranges[i] = draft.range } else { value.program.ranges.append(draft.range) }
        value.intensities[draft.id] = draft.intensity
        var levels = value.brightness ?? [:]; levels[draft.id] = draft.brightness; value.brightness = levels.isEmpty ? nil : levels
        if draft.enabled { value.disabled.remove(draft.id) } else { value.disabled.insert(draft.id) }
        return value
    }
    var body: some View {
        let refusal = controller.lockedRefusal(for: next)
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
                Toggle("Verrouiller aussi la luminosité", isOn: Binding(get: { draft.brightness != nil }, set: { draft.brightness = $0 ? 0.4 : nil }))
                    .toggleStyle(.goalongSwitchInline).accessibilityIdentifier("braise-range-brightness")
                    .disabled(draft.brightness == nil && !controller.canControlBrightness)
                if draft.brightness == nil, !controller.canControlBrightness {
                    Text("Aucun écran de ce Mac ne peut être réglé par Goalong.").font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                }
                if let level = draft.brightness {
                    HStack { Text("Luminosité à"); Spacer(); Text(GoalongUIFormat.percent(level * 100)).monospacedDigit().foregroundStyle(LHTheme.secondaryText) }
                    Slider(value: Binding(get: { level }, set: { draft.brightness = $0 }), in: BrightnessLockRules.levelRange)
                        .accessibilityLabel("Luminosité de la plage").accessibilityValue("\(Int(level * 100)) pour cent")
                }
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
                // Same consent as a locked block (T-048 B5): a protected range arms the guard only once it is accepted.
                if Self.showsConsent(lock: draft.range.effectiveLock, needed: blocking.guardNeedsConsent) {
                    Text(GuardConsent.text).foregroundStyle(LHTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("braise-guard-consent")
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
                    do {
                        try controller.saveRange(draft.range, intensity: draft.intensity, enabled: draft.enabled, brightness: .some(draft.brightness))
                        if Self.showsConsent(lock: draft.range.effectiveLock, needed: blocking.guardNeedsConsent) { blocking.recordGuardConsent() }
                        dismiss()
                    }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(LHPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(!RedScreenProgram.isUsable(draft.range) || !unreadableFields.isEmpty || refusal != nil)
            }
        }.font(.system(size: 13)).padding(28).frame(width: 590)
            .background(LHTheme.pageBackground).foregroundStyle(LHTheme.text)
            // Not the stop or password sheets of Braise: those stay out of this mechanism.
            .goalongDismissOnOutsideClick(isDirty: { draft != initial || !unreadableFields.isEmpty }, onCancel: { dismiss() })
    }
    /// A protected range (any stop rule but « Libre ») shows `GuardConsent.text` while consent is needed; saving it accepts.
    static func showsConsent(lock: BlockLock, needed: Bool) -> Bool { lock != .free && needed }
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
