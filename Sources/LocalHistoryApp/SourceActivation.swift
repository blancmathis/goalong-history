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
            case .accessibility: return "Allow Accessibility"
            case .inputMonitoring: return "Allow Input Monitoring"
            case .fullDiskAccess: return "Open System Settings"
            case .screenTimeSetup: return "Open Screen Time"
            case .ready, .unavailable: return "Try again"
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
            case .ready: return "The required access is available."
            case .accessibility: return "Allow Goalong History in Privacy & Security → Accessibility. Return to Goalong to finish connecting this source. Your sharing settings are unchanged."
            case .inputMonitoring: return "Allow Input Monitoring for Goalong in System Settings, then return here to verify access."
            case .fullDiskAccess: return "Allow Goalong History in Privacy & Security → Full Disk Access. If macOS asks, choose Quit & Reopen; Goalong will return to setup. You can continue without this source."
            case .screenTimeSetup: return "No Apple Screen Time source is available yet. Turn on App & Website Activity in macOS Screen Time, then check again."
            case .unavailable(let message): return message
            }
        }
    }

    extension GoalongCapability {
        var accessExplanation: String {
            switch self {
            case .localComputerHistory:
                return "To build your activity timeline, Goalong needs Accessibility access to identify the app and window you use. Input access lets it count interactions without recording what you type. Recording is local. Optional analysis and website sharing have separate controls."
            case .appleScreenTime:
                return "To show time spent in your apps, Goalong reads Apple’s Screen Time files. macOS protects these files with Full Disk Access, a broad permission you control in System Settings."
            case .aiConversations:
                return "Goalong needs to read the conversation folders you selected to show your local AI history. Conversation bodies stay in their original files."
            default: return "Goalong needs access to this source to show its activity."
            }
        }
    }

    enum SourceAccessService {
        typealias Check = (GoalongCapability, @escaping (SourceAccessStatus) -> Void) -> Void

        static func check(_ capability: GoalongCapability, completion: @escaping (SourceAccessStatus) -> Void) {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = probe(capability)
                DispatchQueue.main.async { completion(result) }
            }
        }

        private static func probe(_ capability: GoalongCapability) -> SourceAccessStatus {
            guard !GoalongGlobalPause.isPaused() else { return .unavailable("Pause globale : reprenez Goalong pour vérifier cet accès.") }
            switch capability {
            case .localComputerHistory:
                return computerHistoryAccess(PermissionManager.activationStatus())
            case .appleScreenTime:
                switch AppleSystemScreenTimeSource(deviceID: "access-check").activationAccess() {
                case .available: return .ready
                case .permissionRequired: return .fullDiskAccess
                case .noData: return .screenTimeSetup
                case .unavailable: return .unavailable("The Apple source could not be opened. Check Screen Time in System Settings and try again.")
                }
            case .aiConversations:
                // Only validate folders the person has already selected; do not discover or scan transcripts.
                guard let store = try? AgentActivityStore(rootDirectory: AppPaths.agentActivityDirectory) else {
                    return .unavailable("Conversation settings could not be opened. Try again before enabling this source.")
                }
                for folder in store.loadConfiguration().watchedFolders where folder.isEnabled {
                    let descriptor = folder.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                    if descriptor >= 0 { Darwin.close(descriptor) }
                    else if errno == EPERM || errno == EACCES { return .fullDiskAccess }
                    else { return .unavailable("A selected conversation folder is unavailable. Review its location in Settings → Sources, then try again.") }
                }
                return .ready
            default: return .ready
            }
        }

        // Permission and live capture health are separate. An app that cannot answer
        // a focused-window probe must not revoke the user's source consent.
        static func computerHistoryAccess(_ status: PermissionStatus) -> SourceAccessStatus {
            // A successful AX read can describe our own window after TCC was reset.
            // Activation requires macOS permission, not merely a functional read.
            guard status.accessibilityPreflight else { return .accessibility }
            return status.canAttemptInputTap ? .ready : .inputMonitoring
        }

        static func openAccess(_ status: SourceAccessStatus) {
            let permissions = PermissionManager()
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
                let message = "The access check did not finish. Nothing has been enabled. Restart Goalong History and try again."
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
                        ? "Check \(self.completedCheckCount): macOS still denies access to this running copy of Goalong History. The source is not enabled."
                        : "Check \(self.completedCheckCount): this source is not ready. Nothing has been enabled."
                    return
                }
                guard enable else { return }
                do { if !self.store.isEnabled(capability) { try prepare() } }
                catch {
                    self.result = .unavailable("Settings could not be saved: \(error.localizedDescription)")
                    return
                }
                guard self.store.set(capability, enabled: true, surface: surface) else {
                    self.result = .unavailable("Your choice could not be saved. Nothing has been enabled. Try again.")
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
                .toggleStyle(.switch)
                .accessibilityIdentifier("source-\(capability.rawValue)")
                .fixedSize()
            }
            .disabled(checking)
            .sheet(isPresented: $showingActivation) {
                SourceActivationSheet(capability: capability, surface: surface, prepare: prepare, check: checkAccess, initialStatus: activationStatus, resumingAfterRestart: resumingAfterRestart)
            }
            .sheet(isPresented: $showingRecordingReview, onDismiss: {
                if continueAfterRecordingReview {
                    continueAfterRecordingReview = false
                    beginActivation()
                }
            }) {
                if let recordingModel {
                    GoalongRecordingSetupSheet(model: recordingModel, activating: true) {
                        continueAfterRecordingReview = true
                    }
                }
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
            .alert("Access needs attention", isPresented: Binding(
                get: { accessIssue != nil }, set: { if !$0 { accessIssue = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(accessIssue ?? "") }
            .alert("Could not save this change", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: { Text("The source is still enabled. Try turning it off again.") }
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
                    catch { accessIssue = "Settings could not be saved: \(error.localizedDescription)"; return }
                    if !consents.set(capability, enabled: true, surface: surface) {
                        accessIssue = "This setting could not be saved. Please try again."
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
                accessIssue = status.message + " Your saved source choice is unchanged. No new data is available until access works again."
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
        private var needsRestart: Bool { openedSettings && access == .fullDiskAccess && !ready }
        private var primaryTitle: String {
            if restarting { return "Preparing restart…" }
            if flow.checking { return "Checking access…" }
            if ready { return GoalongCapabilityConsentStore.shared.isEnabled(capability) ? "Done" : "Enable \(capability.title)" }
            if needsRestart { return "Quit & reopen" }
            if !openedSettings && access.hasSettingsAction { return "Open System Settings" }
            return "Check access"
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                PermissionSetupHeader(copy: copy, ready: ready).padding(28)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        PermissionSetupStatusCard(copy: copy, checking: flow.checking, ready: ready)
                        if ready {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Access confirmed").font(.system(size: 15, weight: .semibold))
                                Text(GoalongCapabilityConsentStore.shared.isEnabled(capability)
                                     ? "Your saved source choice is unchanged. You can return to your history."
                                     : "Enable this source to finish. Your recording preferences, exclusions and sharing choices stay unchanged.")
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
                                Label(needsRestart ? "Restart to apply access, then finish here." : "Waiting for macOS. We’ll check again when you return.",
                                      systemImage: needsRestart ? "arrow.clockwise.circle" : "clock")
                                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                                    .accessibilityIdentifier("source-access-check-result")
                            }
                            if manualChecks > 0, !flow.checking, flow.feedback != nil {
                                Text("Access is not available to this copy yet. Nothing has been enabled.")
                                    .font(.system(size: 12)).foregroundStyle(LHTheme.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if access.isMacPermission && (openedSettings || resumingAfterRestart || manualChecks > 0) {
                                PermissionRecoveryView(status: access, capability: capability, expandOnFailure: !needsRestart && (manualChecks > 0 || resumingAfterRestart))
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
                    Button("Not now", role: .cancel) { PermissionRecovery.clearSetup(); flow.cancel(); dismiss() }
                        .keyboardShortcut(.cancelAction).buttonStyle(.plain)
                        .foregroundStyle(LHTheme.secondaryText).disabled(restarting)
                    Spacer(minLength: 8)
                    if openedSettings && !ready {
                        Button(needsRestart ? "Check again" : "Open settings") {
                            if needsRestart { manualChecks += 1; check() } else { openSettings() }
                        }.buttonStyle(.bordered).disabled(flow.checking || restarting)
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
                if let recordingModel {
                    GoalongRecordingSetupSheet(model: recordingModel, activating: true) { continueAfterRecordingReview = true }
                }
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

    @MainActor struct SourceAccessGate<Content: View>: View {
        let capability: GoalongCapability
        var knownAccessIssue: SourceAccessStatus? = nil
        @ViewBuilder var content: () -> Content
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
        @Environment(\.sourceAccessCheck) private var checkAccess
        @StateObject private var validation = SourceAccessValidation()

        var body: some View {
            Group {
                if !consents.isEnabled(capability) || validation.result == .ready {
                    content()
                } else if validation.checking {
                    ProgressView("Checking access…").padding(LHTheme.pageInset)
                } else if let status = validation.result {
                    LHCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Access for \(capability.title)").font(.system(size: 15, weight: .semibold))
                            Text(capability.accessExplanation).font(.system(size: 13)).foregroundStyle(.secondary)
                            Text(status.message).font(.system(size: 13))
                            if status.isMacPermission { PermissionRecoveryView(status: status, capability: capability) }
                            Text("Your source choice is unchanged. Missing access is not evidence of inactivity.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                if status.hasSettingsAction {
                                    Button(status.actionTitle) { PermissionRecovery.rememberSetup(capability); SourceAccessService.openAccess(status) }
                                        .buttonStyle(LHPrimaryButtonStyle())
                                }
                                Button("Check access again") { validate() }.buttonStyle(.bordered)
                            }
                        }.fixedSize(horizontal: false, vertical: true)
                    }.padding(LHTheme.pageInset)
                } else {
                    ProgressView("Checking access…").padding(LHTheme.pageInset)
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
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Computer History is off").font(.system(size: 15, weight: .semibold))
                        Text("Enable local activity recording to view this timeline. We will explain and verify the required macOS access first.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    SourceActivationToggle(capability: .localComputerHistory) { Text("Computer History") }
                        .labelsHidden()
                }
            }
        }
    }
#endif
