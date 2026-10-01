#if os(macOS)
import LocalHistoryCore
    import AppKit
    import AgentActivity
    import AppleSystemScreenTime
    import Combine
    import Darwin
    import SwiftUI

    enum SourceAccessStatus: Equatable {
        case ready, accessibility, inputMonitoring, fullDiskAccess, screenTimeSetup
        case unavailable(String)

        var actionTitle: String {
            switch self {
            case .accessibility: return "Autoriser l’accessibilité"
            case .inputMonitoring: return "Autoriser la surveillance de l’entrée"
            case .fullDiskAccess: return "Ouvrir Réglages Système"
            case .screenTimeSetup: return "Ouvrir Temps d’écran"
            case .ready, .unavailable: return "Réessayer"
            }
        }

        var isMacPermission: Bool {
            switch self {
            case .accessibility, .inputMonitoring, .fullDiskAccess: return true
            case .ready, .screenTimeSetup, .unavailable: return false
            }
        }

        var hasSettingsAction: Bool {
            switch self {
            case .accessibility, .inputMonitoring, .fullDiskAccess, .screenTimeSetup: return true
            case .ready, .unavailable: return false
            }
        }

        var message: String {
            switch self {
            case .ready: return "L’accès nécessaire est disponible."
            case .accessibility: return "Autorisez Goalong History dans Confidentialité et sécurité → Accessibilité, puis revenez dans Goalong pour terminer. Vos réglages de partage sont inchangés."
            case .inputMonitoring: return "Autorisez Goalong dans Réglages Système → Surveillance de l’entrée, puis revenez ici pour vérifier l’accès."
            case .fullDiskAccess: return "Autorisez Goalong History dans Confidentialité et sécurité → Accès complet au disque. Si macOS le propose, choisissez Quitter et rouvrir : Goalong reviendra à cette étape. Vous pouvez continuer sans cette source."
            case .screenTimeSetup: return "Aucune donnée Temps d’écran n’est encore disponible. Activez « Activité des apps et des sites web » dans Temps d’écran de macOS, puis vérifiez à nouveau."
            case .unavailable(let message): return message
            }
        }
    }

    extension GoalongCapability {
        var accessExplanation: String {
            switch self {
            case .localComputerHistory:
                return "Pour construire votre historique, Goalong a besoin de l’accès Accessibilité afin de reconnaître l’app et la fenêtre utilisées. L’accès aux entrées lui permet de compter les interactions sans enregistrer ce que vous tapez. Tout reste sur ce Mac ; l’analyse et l’envoi au site se règlent séparément."
            case .appleScreenTime:
                return "Pour afficher le temps passé dans vos apps, Goalong lit les fichiers Temps d’écran d’Apple. macOS les protège par l’accès complet au disque, une autorisation large que vous contrôlez dans Réglages Système."
            case .aiConversations:
                return "Goalong doit lire les dossiers de conversations choisis pour afficher votre historique IA local. Le contenu des conversations reste dans ses fichiers d’origine."
            default: return "Goalong a besoin d’accéder à cette source pour afficher son activité."
            }
        }
    }

    enum SourceAccessService {
        typealias Check = (GoalongCapability, @escaping (SourceAccessStatus) -> Void) -> Void

        static func check(_ capability: GoalongCapability, completion: @escaping (SourceAccessStatus) -> Void) {
            DispatchQueue.global(qos: .userInitiated).async {
                let started = ProcessInfo.processInfo.systemUptime
                let revision = PermissionManager.shared.observationRevision
                let result = probe(capability)
                DispatchQueue.main.async {
                    let invalidated = PermissionManager.shared.isRepairInProgress
                        || PermissionManager.shared.observationRevision != revision
                    SupportDiagnostics.shared.record(.sourceCheck, component: .permissions, values: [
                        .success: .flag(!invalidated && result == .ready),
                        .capability: .state(SupportState(rawValue: capability.rawValue) ?? .unknown),
                        .permission: .state(PermissionRepair.diagnosticState(for: result)),
                        .state: .state(invalidated ? .cancelled : result == .ready ? .ready : .unavailable),
                        .elapsedMS: .number((ProcessInfo.processInfo.systemUptime - started) * 1000)
                    ])
                    guard !invalidated else {
                        completion(.unavailable("Les autorisations ont changé pendant la vérification. Réessayez ; aucun nouvel accès n’a été confirmé."))
                        return
                    }
                    if result == .ready {
                        if capability == .localComputerHistory { PermissionRecoveryLedger.clear(.accessibility) }
                        if capability == .appleScreenTime { PermissionRecoveryLedger.clear(.fullDiskAccess) }
                    }
                    completion(result)
                }
            }
        }

        private static func probe(_ capability: GoalongCapability) -> SourceAccessStatus {
            guard !PermissionManager.shared.isRepairInProgress else {
                return .unavailable("Une réparation d’autorisation est en cours. Aucun nouvel accès n’est confirmé.")
            }
            guard !GoalongGlobalPause.isPaused() else { return .unavailable("Pause globale : reprenez Goalong pour vérifier cet accès.") }
            switch capability {
            case .localComputerHistory:
                return computerHistoryAccess(PermissionManager.activationStatus(), inputTapCreationFailed: PermissionManager.shared.inputTapCreationFailed)
            case .appleScreenTime:
                switch AppleSystemScreenTimeSource(deviceID: "access-check").activationAccess() {
                case .available: return .ready
                case .permissionRequired: return .fullDiskAccess
                case .noData: return .screenTimeSetup
                case .unavailable: return .unavailable("La source Apple n’a pas pu être ouverte. Vérifiez Temps d’écran dans Réglages Système, puis réessayez.")
                }
            case .aiConversations:
                // Only validate folders the person has already selected; do not discover or scan transcripts.
                guard let store = try? AgentActivityStore(rootDirectory: AppPaths.agentActivityDirectory) else {
                    return .unavailable("Les réglages des conversations n’ont pas pu être ouverts. Réessayez avant d’activer cette source.")
                }
                for folder in store.loadConfiguration().watchedFolders where folder.isEnabled {
                    let descriptor = folder.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                    if descriptor >= 0 { Darwin.close(descriptor) }
                    else if errno == EPERM || errno == EACCES { return .fullDiskAccess }
                    else { return .unavailable("Un dossier de conversations choisi est introuvable. Vérifiez son emplacement dans Réglages → Sources, puis réessayez.") }
                }
                return .ready
            default: return .ready
            }
        }

        // Permission and live capture health are separate. An app that cannot answer
        // a focused-window probe must not revoke the user's source consent.
        static func computerHistoryAccess(_ status: PermissionStatus, inputTapCreationFailed: Bool = false) -> SourceAccessStatus {
            // A generic/self-window read is not authorization. The manager accepts
            // only TCC preflight or a protected read proven to target another process.
            guard !status.observationPending else { return .unavailable("La vérification est encore en cours. Aucun nouvel accès n’a été confirmé ; réessayez.") }
            guard !status.accessibilityProbeDenied,
                  status.accessibilityPreflight || status.accessibilityCrossProcessProbe else { return .accessibility }
            // Accessibility can permit a listen-only tap, but a failed input path
            // must remain repairable. A direct grant is independent.
            if inputTapCreationFailed && !status.inputMonitoringDirectlyGranted { return .inputMonitoring }
            return status.canAttemptInputTap ? .ready : .inputMonitoring
        }

        static func openAccess(_ status: SourceAccessStatus) {
            PermissionRecoveryLedger.record(.settingsOpened, for: status)
            let permissions = PermissionManager.shared
            switch status {
            case .accessibility:
                permissions.openAccessibilitySettings()
            case .inputMonitoring:
                permissions.openInputMonitoringSettings()
            case .fullDiskAccess: permissions.openFullDiskAccessSettings()
            case .screenTimeSetup:
                if let url = URL(string: "x-apple.systempreferences:com.apple.Screen-Time-Settings.extension") {
                    GoalongWorkspaceOpenPolicy.open(url, purpose: .systemSettings)
                }
            case .ready, .unavailable: break
            }
        }
    }

    /// Consent is written only after a user-initiated check succeeds. Cancellation invalidates in-flight checks.
    final class SourceActivationFlow: ObservableObject {
        @Published private(set) var checking = false
        @Published private(set) var result: SourceAccessStatus?
        @Published private(set) var completed = false
        @Published private(set) var completedCheckCount = 0
        @Published private(set) var feedback: String?
        private var timeoutWorkItem: DispatchWorkItem?
        private let checkTimeout: TimeInterval
        private var generation = 0
        private let store: GoalongCapabilityConsentStore
        private let checkAccess: SourceAccessService.Check

        init(store: GoalongCapabilityConsentStore = .shared, check: @escaping SourceAccessService.Check = SourceAccessService.check, initialStatus: SourceAccessStatus? = nil, checkTimeout: TimeInterval = 8) {
            self.checkTimeout = checkTimeout
            self.store = store
            self.checkAccess = check
            self.result = initialStatus
        }

        func inspect(_ capability: GoalongCapability) {
            runCheck(capability, enable: false, surface: .settings, prepare: {})
        }

        func checkAndEnable(_ capability: GoalongCapability, surface: GoalongConsentSurface, prepare: @escaping () throws -> Void) {
            runCheck(capability, enable: true, surface: surface, prepare: prepare)
        }

        private func runCheck(_ capability: GoalongCapability, enable: Bool, surface: GoalongConsentSurface, prepare: @escaping () throws -> Void) {
            guard !checking, !completed else { return }
            generation += 1
            let request = generation
            checking = true
            feedback = nil
            // Keep the previous result visible while checking; never leave an empty sheet.
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.generation == request, self.checking else { return }
                self.generation += 1
                self.checking = false
                self.completedCheckCount += 1
                let message = "La vérification d’accès n’a pas abouti. Rien n’a été activé. Relancez Goalong History puis réessayez."
                self.feedback = message
                if self.result == nil { self.result = .unavailable(message) }
            }
            timeoutWorkItem?.cancel()
            timeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + checkTimeout, execute: timeout)
            checkAccess(capability) { [weak self] status in
                guard let self, self.generation == request, self.checking else { return }
                self.timeoutWorkItem?.cancel()
                self.timeoutWorkItem = nil
                self.checking = false
                self.completedCheckCount += 1
                self.result = status
                guard status == .ready else {
                    self.feedback = status.isMacPermission
                        ? "Vérification \(self.completedCheckCount) : l’accès n’est pas encore confirmé pour cette copie de Goalong History. La source n’est pas activée."
                        : "Vérification \(self.completedCheckCount) : cette source n’est pas prête. Rien n’a été activé."
                    return
                }
                guard enable else { return }
                do { if !self.store.isEnabled(capability) { try prepare() } }
                catch {
                    self.result = .unavailable("Les réglages n’ont pas pu être enregistrés : \(error.localizedDescription)")
                    return
                }
                guard self.store.set(capability, enabled: true, surface: surface) else {
                    self.result = .unavailable("Votre choix n’a pas pu être enregistré. Rien n’a été activé. Réessayez.")
                    return
                }
                self.completed = true
            }
        }

        func requestMissingAccess(using request: (SourceAccessStatus) -> Void = SourceAccessService.openAccess) {
            guard !checking, let result, result.hasSettingsAction else { return }
            request(result)
        }

        func cancel() {
            generation += 1
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            checking = false
        }

        deinit { timeoutWorkItem?.cancel() }
    }

    private struct SourceAccessCheckKey: EnvironmentKey {
        static let defaultValue: SourceAccessService.Check = SourceAccessService.check
    }
    extension EnvironmentValues {
        var sourceAccessCheck: SourceAccessService.Check {
            get { self[SourceAccessCheckKey.self] }
            set { self[SourceAccessCheckKey.self] = newValue }
        }
    }

    /// An access explanation has no unsaved document to protect. Let macOS quit
    /// the app from System Settings even while this sheet remains open.
    struct PermissionSheetWindowBehavior: NSViewRepresentable {
        func makeNSView(context: Context) -> PermissionSheetWindowView { PermissionSheetWindowView() }
        func updateNSView(_ view: PermissionSheetWindowView, context: Context) {}
    }

    final class PermissionSheetWindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.preventsApplicationTerminationWhenModal = false
        }
    }

    struct SourceActivationToggle<Label: View>: View {
        let capability: GoalongCapability
        var surface: GoalongConsentSurface = .settings
        var prepare: () throws -> Void = {}
        var onCheckingChanged: (Bool) -> Void = { _ in }
        @ViewBuilder var label: () -> Label
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
        @Environment(\.sourceAccessCheck) private var checkAccess
        @Environment(\.goalongRecordingModel) private var recordingModel
        @State private var showingRecordingReview = false
        @State private var continueAfterRecordingReview = false
        @State private var resumingAfterRestart = false
        @State private var showingActivation = false
        @State private var activationStatus: SourceAccessStatus?
        @State private var checking = false
        @State private var saveFailed = false
        @State private var accessIssue: String?
        @State private var validation = UUID()

        var body: some View {
            HStack(spacing: 20) {
                label().frame(maxWidth: .infinity, alignment: .leading)
                Toggle(isOn: Binding(
                    get: { consents.isEnabled(capability) },
                    set: { enabled in
                        if enabled { beginActivation() }
                        else { saveFailed = !consents.set(capability, enabled: false, surface: surface) }
                    }
                )) { Text(capability.title) }
                .labelsHidden()
                .toggleStyle(.goalongSwitchOnly)
                .accessibilityIdentifier("source-\(capability.rawValue)")
                .fixedSize()
            }
            .disabled(checking)
            .sheet(isPresented: $showingActivation) {
                SourceActivationSheet(capability: capability, surface: surface, prepare: prepare, check: checkAccess, initialStatus: activationStatus, resumingAfterRestart: resumingAfterRestart)
                    .goalongControls()
            }
            .sheet(isPresented: $showingRecordingReview, onDismiss: {
                if continueAfterRecordingReview {
                    continueAfterRecordingReview = false
                    beginActivation()
                }
            }) {
                Group {
                if let recordingModel {
                    GoalongRecordingSetupSheet(model: recordingModel, activating: true) {
                        continueAfterRecordingReview = true
                    }
                }
                }.goalongControls()
            }
            .onAppear {
                if PermissionRecovery.takeSetupReturn(for: capability) {
                    resumingAfterRestart = true
                    activationStatus = nil
                    showingActivation = true
                } else { validateExistingConsent() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                validateExistingConsent()
            }
            .onChange(of: consents.isEnabled(capability)) { _ in validation = UUID() }
            .onDisappear { validation = UUID(); checking = false; onCheckingChanged(false) }
            .alert("Accès à vérifier", isPresented: Binding(
                get: { accessIssue != nil }, set: { if !$0 { accessIssue = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(accessIssue ?? "") }
            .alert("Modification non enregistrée", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: { Text("La source est toujours activée. Essayez de la désactiver à nouveau.") }
        }
        private func beginActivation() {
            // A valid macOS permission must not bypass the initial recording choice.
            if capability == .localComputerHistory && !GoalongRecordingSetup.hasReviewedChoices() {
                guard recordingModel != nil else {
                    accessIssue = "Ouvrez Enregistrement pour confirmer les détails à conserver avant d’activer le suivi."
                    return
                }
                continueAfterRecordingReview = false
                showingRecordingReview = true
                return
            }
            resumingAfterRestart = false
            let request = UUID()
            validation = request
            checking = true
            onCheckingChanged(true)
            checkAccess(capability) { status in
                guard validation == request else { return }
                checking = false
                onCheckingChanged(false)
                if status == .ready {
                    do { try prepare() }
                    catch { accessIssue = "Les réglages n’ont pas pu être enregistrés : \(error.localizedDescription)"; return }
                    if !consents.set(capability, enabled: true, surface: surface) {
                        accessIssue = "Ce réglage n’a pas pu être enregistré. Réessayez."
                    }
                } else {
                    activationStatus = status
                    showingActivation = true
                }
            }
        }

        private func validateExistingConsent() {
            guard !checking, !showingActivation else { return }
            let request = UUID()
            validation = request
            guard consents.isEnabled(capability), !showingActivation else { return }
            checkAccess(capability) { status in
                guard validation == request, consents.isEnabled(capability), !showingActivation,
                      status != .ready else { return }
                guard activationStatus != status else { return }
                activationStatus = status
                accessIssue = status.message + " Votre choix de source est inchangé. Aucune nouvelle donnée tant que l’accès ne fonctionne pas."
            }
        }
    }

    struct SourceActivationSheet: View {
        let capability: GoalongCapability
        let surface: GoalongConsentSurface
        let prepare: () throws -> Void
        let resumingAfterRestart: Bool
        @StateObject private var flow: SourceActivationFlow
        @Environment(\.dismiss) private var dismiss
        @Environment(\.goalongRecordingModel) private var recordingModel
        @State private var showingRecordingReview = false
        @State private var continueAfterRecordingReview = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var openedSettings = false
        @State private var restarting = false
        @State private var restartError: String?
        @State private var manualChecks = 0
        @State private var watchUntil = Date.distantPast
        private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

        init(capability: GoalongCapability, surface: GoalongConsentSurface, prepare: @escaping () throws -> Void,
             check: @escaping SourceAccessService.Check, initialStatus: SourceAccessStatus? = nil, resumingAfterRestart: Bool = false) {
            self.capability = capability; self.surface = surface; self.prepare = prepare
            self.resumingAfterRestart = resumingAfterRestart
            _flow = StateObject(wrappedValue: SourceActivationFlow(check: check, initialStatus: initialStatus))
        }

        private var access: SourceAccessStatus { flow.result ?? (capability == .appleScreenTime ? .fullDiskAccess : .accessibility) }
        private var copy: PermissionSetupCopy { PermissionSetupCopy(capability: capability, status: access) }
        private var ready: Bool { flow.result == .ready }
        private var needsRestart: Bool {
            PermissionRecoveryAdvice.prefersPrimaryRelaunch(status: access, openedSettings: openedSettings,
                ready: ready, resumedAfterRestart: resumingAfterRestart,
                progress: PermissionRecoveryLedger.load(access))
        }
        private var primaryTitle: String {
            if restarting { return "Préparation du redémarrage…" }
            if flow.checking { return "Vérification de l’accès…" }
            if ready { return GoalongCapabilityConsentStore.shared.isEnabled(capability) ? "Terminé" : "Activer \(capability.title)" }
            if needsRestart { return "Quitter et rouvrir" }
            if !openedSettings && access.hasSettingsAction { return "Ouvrir Réglages Système" }
            return "Vérifier l’accès"
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                PermissionSetupHeader(copy: copy, ready: ready).padding(28)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        PermissionSetupStatusCard(copy: copy, checking: flow.checking, ready: ready)
                        if ready {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Accès confirmé").font(.system(size: 15, weight: .semibold))
                                Text(GoalongCapabilityConsentStore.shared.isEnabled(capability)
                                     ? "Votre choix de source est inchangé. Vous pouvez revenir à votre historique."
                                     : "Activez cette source pour terminer. Vos préférences d’enregistrement, exclusions et choix de partage restent inchangés.")
                                    .font(.system(size: 13)).foregroundStyle(LHTheme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            PermissionSetupSteps(copy: copy, openedSettings: openedSettings, ready: ready)
                            if case .unavailable(let message) = access {
                                Label(message, systemImage: "exclamationmark.circle")
                                    .font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if openedSettings && !flow.checking {
                                Label(needsRestart ? "Relancez Goalong pour appliquer l’accès, puis terminez ici." : "En attente de macOS. Nouvelle vérification à votre retour.",
                                      systemImage: needsRestart ? "arrow.clockwise.circle" : "clock")
                                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                    .accessibilityIdentifier("source-access-check-result")
                            }
                            if manualChecks > 0, !flow.checking, flow.feedback != nil {
                                Text("L’accès n’est pas encore disponible pour cette copie. Rien n’a été activé.")
                                    .font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if access.isMacPermission && (openedSettings || resumingAfterRestart || manualChecks > 0) {
                                PermissionRecoveryView(status: access, capability: capability, expandOnFailure: !needsRestart && (manualChecks > 0 || resumingAfterRestart), resumedAfterRestart: resumingAfterRestart)
                                    .disabled(flow.checking || restarting)
                            }
                        }
                        Rectangle().fill(LHTheme.separator).frame(height: 1)
                        PermissionPrivacyNote(text: copy.privacy)
                        if let restartError { Text(restartError).font(.system(size: 12)).foregroundStyle(LHTheme.danger).fixedSize(horizontal: false, vertical: true) }
                    }.padding(.horizontal, 28).padding(.bottom, 24)
                }
                .frame(maxHeight: min(ready ? 250 : 465, (NSScreen.main?.visibleFrame.height ?? 900) * 0.53))
                Rectangle().fill(LHTheme.separator).frame(height: 1)
                HStack(spacing: 12) {
                    Button("Plus tard", role: .cancel) { PermissionRecovery.clearSetup(); flow.cancel(); dismiss() }
                        .keyboardShortcut(.cancelAction).buttonStyle(.plain)
                        .foregroundStyle(LHTheme.secondaryText).disabled(restarting)
                    Spacer(minLength: 8)
                    if openedSettings && !ready {
                        Button(needsRestart ? "Vérifier à nouveau" : "Ouvrir les réglages") {
                            if needsRestart { manualChecks += 1; check() } else { openSettings() }
                        }.buttonStyle(LHSecondaryButtonStyle()).disabled(flow.checking || restarting)
                    }
                    Button(primaryTitle) { primaryAction() }
                        .buttonStyle(LHPrimaryButtonStyle()).controlSize(.large)
                        .disabled(flow.checking || restarting)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("permission-primary-action")
                }
                .font(.system(size: 12, weight: .medium)).padding(.horizontal, 28).padding(.vertical, 20)
                .background(LHTheme.cardBackground)
            }
            .frame(width: 576)
            .foregroundStyle(LHTheme.text).tint(LHTheme.accent)
            .background(LHTheme.pageBackground)
            .background(PermissionSheetWindowBehavior())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: ready)
            .sheet(isPresented: $showingRecordingReview, onDismiss: {
                if continueAfterRecordingReview { continueAfterRecordingReview = false; check() }
            }) {
                Group {
                if let recordingModel {
                    GoalongRecordingSetupSheet(model: recordingModel, activating: true) { continueAfterRecordingReview = true }
                }
                }.goalongControls()
            }
            .onAppear {
                openedSettings = resumingAfterRestart
                if flow.result == nil { check() }
            }
            .onChange(of: flow.completed) {
                if $0 { PermissionRecovery.clearSetup(); dismiss() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if openedSettings && !flow.checking && !restarting { check() }
            }
            .onReceive(refreshTimer) { now in
                if openedSettings && now < watchUntil && NSApplication.shared.isActive && !flow.checking && !ready && !restarting { check() }
            }
            .onDisappear { flow.cancel() }
        }

        private func recordingChoicesReady() -> Bool {
            guard capability == .localComputerHistory,
                  !GoalongCapabilityConsentStore.shared.isEnabled(capability),
                  !GoalongRecordingSetup.hasReviewedChoices() else { return true }
            guard recordingModel != nil else {
                restartError = "Confirmez les détails d’enregistrement depuis les réglages avant d’activer ce suivi."
                return false
            }
            showingRecordingReview = true
            return false
        }
        private func check() {
            guard recordingChoicesReady() else { return }
            // Across process restarts, restore context but require a new explicit Enable click.
            if resumingAfterRestart { flow.inspect(capability) }
            else { flow.checkAndEnable(capability, surface: surface, prepare: prepare) }
        }
        private func openSettings() {
            PermissionRecovery.rememberSetup(capability)
            openedSettings = true
            watchUntil = Date().addingTimeInterval(180)
            flow.requestMissingAccess()
        }
        private func primaryAction() {
            guard recordingChoicesReady() else { return }
            if ready {
                if GoalongCapabilityConsentStore.shared.isEnabled(capability) { PermissionRecovery.clearSetup(); dismiss() }
                else { flow.checkAndEnable(capability, surface: surface, prepare: prepare) }
            } else if needsRestart {
                PermissionRecovery.rememberSetup(capability)
                restarting = true; restartError = nil
                PermissionRecovery.restart { error in restartError = error; restarting = error == nil }
            } else if !openedSettings && access.hasSettingsAction { openSettings() }
            else { manualChecks += 1; check() }
        }
    }

    /// Passive navigation can inspect existing consent, never grant or revoke it.
    /// In-flight results are discarded after navigation or a changed source choice.
    final class SourceAccessValidation: ObservableObject {
        @Published private(set) var checking = false
        @Published private(set) var result: SourceAccessStatus?
        private var generation = UUID()
        private let store: GoalongCapabilityConsentStore

        init(store: GoalongCapabilityConsentStore = .shared) { self.store = store }

        func validate(_ capability: GoalongCapability, check: @escaping SourceAccessService.Check) {
            let request = UUID(); generation = request
            guard store.isEnabled(capability) else { checking = false; result = nil; return }
            checking = true
            check(capability) { [weak self] status in
                guard let self, self.generation == request else { return }
                self.checking = false
                self.result = self.store.isEnabled(capability) ? status : nil
            }
        }
        func cancel() { generation = UUID(); checking = false }
        func report(_ status: SourceAccessStatus) { cancel(); result = status }
    }

    /// Presentation only; never changes consent or runs a permission check.
    enum SourceAccessPresentation: Equatable {
        case content, loading, issue(SourceAccessStatus)
        static func resolve(enabled: Bool, checking: Bool, result: SourceAccessStatus?) -> Self {
            // A usable page stays visible during passive revalidation.
            if !enabled || result == .ready { return .content }
            if checking { return .loading }
            if let result { return .issue(result) }
            return .loading
        }
    }

    @MainActor struct SourceAccessGate<Content: View>: View {
        let capability: GoalongCapability
        var knownAccessIssue: SourceAccessStatus? = nil
        @ViewBuilder var content: () -> Content
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
        @Environment(\.sourceAccessCheck) private var checkAccess
        @StateObject private var validation = SourceAccessValidation()

        var body: some View {
            Group {
                switch SourceAccessPresentation.resolve(enabled: consents.isEnabled(capability),
                                                        checking: validation.checking, result: validation.result) {
                case .content:
                    content()
                case .loading:
                    GoalongPageLoadingView(title: "Vérification des accès…")
                        .accessibilityIdentifier("source-access-page-loading")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(LHTheme.pageInset)
                case .issue(let status):
                    LHCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Accès pour \(capability.title)").font(.system(size: 15, weight: .semibold))
                            Text(capability.accessExplanation).font(.system(size: 13)).foregroundStyle(.secondary)
                            Text(status.message).font(.system(size: 13))
                            if status.isMacPermission { PermissionRecoveryView(status: status, capability: capability) }
                            Text("Votre choix de source est inchangé. Un accès manquant ne signifie pas une absence d’activité.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                if status.hasSettingsAction {
                                    Button(status.actionTitle) { PermissionRecovery.rememberSetup(capability); SourceAccessService.openAccess(status) }
                                        .buttonStyle(LHPrimaryButtonStyle())
                                }
                                Button("Vérifier l’accès à nouveau") { validate() }.buttonStyle(LHSecondaryButtonStyle())
                            }
                        }.fixedSize(horizontal: false, vertical: true)
                    }.padding(LHTheme.pageInset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { validate() }
            .onChange(of: consents.isEnabled(capability)) { _ in validate() }
            .onChange(of: knownAccessIssue) { issue in
                if let issue { validation.report(issue) } else { validate() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in validate() }
            .onDisappear { validation.cancel() }
        }
        private func validate() { validation.validate(capability, check: checkAccess) }
    }

    struct ComputerHistoryActivationCard: View {
        @ObservedObject var model: DashboardViewModel
        var body: some View {
            LHCard {
                // The explanation is the switch's own label: no second, floating title.
                SourceActivationToggle(capability: .localComputerHistory) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("L’historique de ce Mac est désactivé").font(.system(size: 15, weight: .semibold))
                        Text("Activez l’enregistrement local pour afficher cette chronologie. Goalong vous explique et vérifie d’abord les accès macOS nécessaires.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
#endif
