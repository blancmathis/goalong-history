#if os(macOS)
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
            case .accessibility: return "In Privacy & Security → Accessibility, enable Goalong History. If it is already enabled but this check fails, macOS may still be authorizing an older app copy. Use the recovery steps below. Granting macOS access alone does not enable a source."
            case .inputMonitoring: return "Allow Input Monitoring for Goalong in System Settings, then return here to verify access."
            case .fullDiskAccess: return "In Privacy & Security → Full Disk Access, enable Goalong History. After changing this permission, restart Goalong History before checking again. If the switch is already on, use the recovery steps below to replace an older app entry. You may also continue without this source."
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

        func checkAndEnable(_ capability: GoalongCapability, surface: GoalongConsentSurface, prepare: @escaping () throws -> Void) {
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
                self.feedback = "The access check did not finish. Nothing has been enabled. Restart Goalong History and try again."
                if self.result == nil { self.result = .unavailable(self.feedback!) }
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
                .fixedSize()
            }
            .disabled(checking)
            .sheet(isPresented: $showingActivation) {
                SourceActivationSheet(capability: capability, surface: surface, prepare: prepare, check: checkAccess, initialStatus: activationStatus)
            }
            .onAppear { validateExistingConsent() }
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
        @StateObject private var flow: SourceActivationFlow
        @Environment(\.dismiss) private var dismiss
        @State private var openedSettings = false

        init(capability: GoalongCapability, surface: GoalongConsentSurface, prepare: @escaping () throws -> Void,
             check: @escaping SourceAccessService.Check, initialStatus: SourceAccessStatus? = nil) {
            self.capability = capability; self.surface = surface; self.prepare = prepare
            _flow = StateObject(wrappedValue: SourceActivationFlow(check: check, initialStatus: initialStatus))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("Access for \(capability.title)").font(.system(size: 22, weight: .semibold))
                Text(capability.accessExplanation).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status = flow.result, status != .ready {
                    Text(status.message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
                if flow.checking {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Checking macOS access…").font(.system(size: 12))
                    }
                    .accessibilityLabel("Checking macOS access")
                } else if let feedback = flow.feedback {
                    Text(feedback).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("source-access-check-result")
                }
                if let status = flow.result, status.isMacPermission {
                    PermissionRecoveryView(status: status, expandOnFailure: flow.completedCheckCount > 0)
                        .disabled(flow.checking)
                }
                HStack(spacing: 10) {
                    Button("Not now", role: .cancel) { flow.cancel(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if let status = flow.result, status.hasSettingsAction {
                        Button(status.actionTitle) {
                            openedSettings = true
                            flow.requestMissingAccess()
                        }.disabled(flow.checking)
                    }
                    Button(flow.checking ? "Checking…" : "Check access") { check() }
                        .buttonStyle(LHPrimaryButtonStyle())
                        .disabled(flow.checking)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(28).frame(width: 560)
            .background(LHTheme.pageBackground)
            .background(PermissionSheetWindowBehavior())
            .onAppear { if flow.result == nil { check() } }
            .onChange(of: flow.completed) { if $0 { dismiss() } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if openedSettings && !flow.checking { check() }
            }
            .onDisappear { flow.cancel() }
        }

        private func check() { flow.checkAndEnable(capability, surface: surface, prepare: prepare) }
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
                            if status.isMacPermission { PermissionRecoveryView(status: status) }
                            Text("Your source choice is unchanged. Missing access is not evidence of inactivity.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                if status.hasSettingsAction {
                                    Button(status.actionTitle) { SourceAccessService.openAccess(status) }
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
