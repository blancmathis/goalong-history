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

        var hasSettingsAction: Bool {
            switch self {
            case .accessibility, .inputMonitoring, .fullDiskAccess, .screenTimeSetup: return true
            case .ready, .unavailable: return false
            }
        }

        var message: String {
            switch self {
            case .ready: return "The required access is available."
            case .accessibility: return "Allow Accessibility for Goalong in System Settings, then return here to verify access."
            case .inputMonitoring: return "Allow Input Monitoring for Goalong in System Settings, then return here to verify access."
            case .fullDiskAccess: return "Allow Full Disk Access for Goalong in System Settings, then return here. macOS may require you to quit and reopen Goalong before the change takes effect."
            case .screenTimeSetup: return "No Apple Screen Time source is available yet. Turn on App & Website Activity in macOS Screen Time, then check again."
            case .unavailable(let message): return message
            }
        }
    }

    extension GoalongCapability {
        var accessExplanation: String {
            switch self {
            case .localComputerHistory:
                return "To build your activity timeline, Goalong needs Accessibility access to identify the app and window you use. Input access lets it count interactions without recording what you type. Activity stays on this Mac."
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
                return computerHistoryAccess(PermissionManager().snapshot)
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
        private var generation = 0
        private let store: GoalongCapabilityConsentStore
        private let checkAccess: SourceAccessService.Check

        init(store: GoalongCapabilityConsentStore = .shared, check: @escaping SourceAccessService.Check = SourceAccessService.check, initialStatus: SourceAccessStatus? = nil) {
            self.store = store
            self.checkAccess = check
            self.result = initialStatus
        }

        func checkAndEnable(_ capability: GoalongCapability, surface: GoalongConsentSurface, prepare: @escaping () throws -> Void) {
            guard !checking else { return }
            generation += 1
            let request = generation
            checking = true
            result = nil
            checkAccess(capability) { [weak self] status in
                guard let self, self.generation == request else { return }
                self.checking = false
                self.result = status
                guard status == .ready else { return }
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

        func cancel() { generation += 1; checking = false }
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
                if consents.set(capability, enabled: false, surface: surface) {
                    accessIssue = status.message + " This source is now off. Turn it on again to check access."
                } else { saveFailed = true }
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
                HStack(spacing: 10) {
                    Button("Not now", role: .cancel) { flow.cancel(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if openedSettings {
                        Button("Check access") { check() }.disabled(flow.checking)
                    }
                    Button(flow.checking ? "Checking access…" : flow.result?.actionTitle ?? "Checking access…") {
                        if let status = flow.result, status.hasSettingsAction {
                            openedSettings = true
                            flow.requestMissingAccess()
                        } else { check() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(flow.checking || flow.result == nil)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(28).frame(width: 520)
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

    /// Opening a history source uses existing access directly; missing access is explained in place.
    struct SourceAccessGate<Content: View>: View {
        let capability: GoalongCapability
        var automaticallyEnable = true
        var prepare: () throws -> Void = {}
        var knownAccessIssue: SourceAccessStatus? = nil
        @ViewBuilder var content: () -> Content
        @ObservedObject private var consents = GoalongCapabilityConsentStore.shared
        @Environment(\.sourceAccessCheck) private var checkAccess
        @State private var hasPresentedContent = false
        @State private var checking = true
        @State private var generation = UUID()
        @State private var requiredAccess: SourceAccessStatus?
        @State private var openedSettings = false

        var body: some View {
            ZStack(alignment: .topLeading) {
                if hasPresentedContent || (!checking && requiredAccess == nil && !consents.isEnabled(capability)) {
                    content()
                        .opacity(checking || requiredAccess != nil ? 0 : 1)
                        .allowsHitTesting(!checking && requiredAccess == nil)
                        .accessibilityHidden(checking || requiredAccess != nil)
                }
                if checking {
                    ProgressView("Checking access…").controlSize(.small).padding(LHTheme.pageInset)
                } else if let status = requiredAccess {
                    LHCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Access for \(capability.title)").font(.system(size: 15, weight: .semibold))
                            Text(capability.accessExplanation).font(.system(size: 13)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(status.message).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 10) {
                                Button(status.actionTitle) {
                                    if status.hasSettingsAction {
                                        openedSettings = true
                                        SourceAccessService.openAccess(status)
                                    } else { validate(allowAutomaticEnable: true) }
                                }.buttonStyle(.borderedProminent)
                                if openedSettings { Button("Check access") { validate(allowAutomaticEnable: true) } }
                            }
                        }
                    }.padding(.horizontal, LHTheme.pageInset).padding(.top, 18)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { validate(allowAutomaticEnable: automaticallyEnable) }
            .onChange(of: consents.isEnabled(capability)) { enabled in
                if enabled { validate() }
                else {
                    generation = UUID(); checking = false; hasPresentedContent = false
                    requiredAccess = automaticallyEnable ? (knownAccessIssue ?? requiredAccess) : nil
                }
            }
            .onChange(of: knownAccessIssue) { issue in
                if let issue {
                    generation = UUID(); checking = false; hasPresentedContent = false
                    requiredAccess = issue
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in validate(allowAutomaticEnable: openedSettings) }
            .onDisappear { generation = UUID(); checking = false }
        }

        private func validate(allowAutomaticEnable: Bool = false) {
            guard allowAutomaticEnable || consents.isEnabled(capability) else {
                if !automaticallyEnable { requiredAccess = nil; checking = false }
                return
            }
            let request = UUID()
            generation = request
            checking = true
            checkAccess(capability) { status in
                guard generation == request else { return }
                checking = false
                if status == .ready {
                    if !consents.isEnabled(capability) {
                        do { try prepare() }
                        catch { requiredAccess = .unavailable("Settings could not be saved: \(error.localizedDescription)"); return }
                        guard consents.set(capability, enabled: true, surface: .settings) else {
                            requiredAccess = .unavailable("This setting could not be saved. Please try again.")
                            return
                        }
                    }
                    requiredAccess = nil
                    openedSettings = false
                    hasPresentedContent = true
                } else {
                    requiredAccess = status
                    hasPresentedContent = false
                    if consents.isEnabled(capability) {
                        _ = consents.set(capability, enabled: false, surface: .settings)
                    }
                }
            }
        }
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
                    SourceActivationToggle(capability: .localComputerHistory,
                        prepare: { try model.configureCaptureForOnboarding(enabled: true) }) { Text("Computer History") }
                        .labelsHidden()
                }
            }
        }
    }
#endif
