#if os(macOS)
import Darwin
import Foundation
import GoalongGuardCore
@preconcurrency import ServiceManagement
@preconcurrency import XPC

/// The app's side of the blocking guard (spec K): a launchd user agent embedded in this bundle that
/// reopens Goalong when it is killed during a severe block. Injected into `BlockingController`.
@MainActor protocol GoalongGuardClienting: AnyObject {
    /// Called by a refresh once the guard state may be stale (a ping answered, a status read).
    var onChange: (() -> Void)? { get set }
    /// True until the guard was registered once: confirmations that can arm it show `GuardConsent.text`.
    var needsConsent: Bool { get }
    /// The service is registered and could be removed (only outside a severe block; the caller checks).
    var canRemove: Bool { get }
    /// `severeUntil` from the controller, after the marker was written. Never raises an alert.
    func update(severeUntil: Date?) -> BlockingProtectionState.Component
    /// Removes the service (button outside a severe block). Next arming registers it again.
    func removeService()
}

/// The one sentence a member reads before the first registration (spec K §6).
enum GuardConsent {
    /// Adds the sentence only while the guard was never registered.
    static func message(_ base: String, needed: Bool) -> String { needed ? base + "\n\n" + text : base }

    static let text = "Pour que ce blocage tienne même si Goalong est forcé à quitter, Goalong ajoute un petit service d’arrière-plan. macOS l’annoncera une fois. Aucun mot de passe n’est demandé. Il ne tourne que pendant les blocages verrouillés ou protégés par mot de passe."
}

/// Only an installed copy of Goalong or Goalong Dev may register its guard: never a translocated
/// copy, a build folder or a test runner. Independent of `GoalongLoginItemGate`.
enum GoalongGuardGate {
    static var isAllowed: Bool {
        isAllowed(bundleURL: Bundle.main.bundleURL, info: Bundle.main.infoDictionary ?? [:], home: realHome)
    }

    static func isAllowed(bundleURL: URL, info: [String: Any], home: URL) -> Bool {
        guard GuardIdentity(bundleIdentifier: info["CFBundleIdentifier"] as? String,
                            channel: info[GuardIdentity.channelKey] as? String) != nil else { return false }
        let path = bundleURL.standardizedFileURL.path
        guard bundleURL.pathExtension == "app", !path.contains("/AppTranslocation/") else { return false }
        let roots = ["/Applications/", home.standardizedFileURL.path + "/Applications/"]
        return roots.contains { path.hasPrefix($0) }
    }

    /// The account's real home, not `CFFIXED_USER_HOME`.
    private static var realHome: URL {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return URL(fileURLWithPath: NSHomeDirectory()) }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }

    static var identity: GuardIdentity? {
        GuardIdentity(bundleIdentifier: Bundle.main.bundleIdentifier,
                      channel: Bundle.main.object(forInfoDictionaryKey: GuardIdentity.channelKey) as? String)
    }
}

/// Exchange files of this copy (`<data root>/Blocking`), with the parent's symlinks resolved once.
enum GoalongGuardFiles {
    static func files(for directory: URL) -> GuardFiles {
        GuardFiles(directory: GuardSystem.realPath(directory.deletingLastPathComponent())
            .appendingPathComponent(directory.lastPathComponent, isDirectory: true))
    }
    static var standard: GuardFiles { files(for: BlockingStore.standard.directory) }

    /// The app was reopened by its guard: no window, no "previous session" banner.
    static var isGuardRelaunch: Bool { CommandLine.arguments.contains(GuardIdentity.relaunchArgument) }

    /// Sparkle or the relauncher will reopen this copy: the guard waits instead of racing them.
    /// Written only while the guard is armed, so nothing changes for a member without a severe block.
    static func writeLease(_ reason: String, seconds: TimeInterval, files: GuardFiles = standard) {
        guard files.markerExists() else { return }
        files.writeLease(GuardLease(pid: getpid(), reason: reason, until: Date().timeIntervalSince1970 + seconds))
    }

    /// An installer runs with the documented override (`--unregister-guard` wrote `guard-override`):
    /// the app neither re-registers the guard nor ignores SIGTERM until the token is stale.
    static func overrideActive(_ files: GuardFiles = standard, now: Date = Date()) -> Bool {
        files.readOverride()?.isFresh(now: now.timeIntervalSince1970) == true
    }

    /// A guard may still hold an armed window: the marker exists, or a guard killed by a signal left its
    /// memory in `guard-state.json` (it would restore it). A block ended early by password removes the
    /// marker, yet such a guard, restarted later in this boot, must still find this quit's token.
    static func guardMayBeArmed(_ files: GuardFiles) -> Bool {
        files.markerExists() || files.readState()?.endContinuous != nil
    }

    /// Written once the blocking runtime runs: from now on this process may lower or remove the marker.
    static func reportHealth(_ files: GuardFiles = standard) {
        files.writeHealth(GuardHealth(pid: getpid(), at: Date().timeIntervalSince1970))
    }
}

/// `Goalong --unregister-guard`, called by uninstall.sh and the installers before they replace or remove
/// the bundle. Refused (exit 3) while `guard-until` is in the future, unless the override variable is set.
enum GuardUnregisterCommand {
    static let argument = "--unregister-guard"
    static let refusedExitCode: Int32 = 3
    static let overrides = ["GOALONG_UNINSTALL_DURING_LOCK", "GOALONG_INSTALL_DURING_LOCK"]

    static func isRefused(marker: GuardMarker, now: Date, environment: [String: String]) -> Bool {
        guard case .date(let end) = marker, end > now else { return false }
        return !overrides.contains { environment[$0] == "1" }
    }

    /// Not refused and a severe block runs: the override was used.
    static func writesOverride(marker: GuardMarker, now: Date) -> Bool {
        if case .date(let end) = marker, end > now { return true }
        return false
    }

    /// Runs the command and exits. Never touches another copy's guard: the plist name is this bundle's own.
    static func run() -> Never {
        guard let identity = GoalongGuardGate.identity else { exit(0) }
        let files = GoalongGuardFiles.standard
        let marker = files.readMarker(now: Date())
        if isRefused(marker: marker, now: Date(), environment: ProcessInfo.processInfo.environment) {
            FileHandle.standardError.write(Data("Un blocage sévère est actif : le service de protection reste en place.\n".utf8))
            exit(refusedExitCode)
        }
        // Override during a severe block: tell the running app first, so it does not register the guard
        // again when its XPC connection drops, and honours the installer's SIGTERM.
        if writesOverride(marker: marker, now: Date()) {
            files.writeOverride(GuardOverride(pid: getpid(), writtenAt: Date().timeIntervalSince1970))
        }
        let service = SMAppService.agent(plistName: identity.plistName)
        if service.status != .notRegistered { try? service.unregister() }
        exit(0)
    }
}

/// Records the pid that sent the last SIGTERM (SA_SIGINFO). The handler only stores an integer; the
/// DispatchSource on the main queue makes the decision. pid 1 is launchd: system shutdown or reboot.
enum TerminationSignalSender {
    private nonisolated(unsafe) static let storage: UnsafeMutablePointer<Int32> = {
        let pointer = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        pointer.initialize(to: 0)
        return pointer
    }()

    /// Replaces SIG_IGN with a recording handler. The kqueue signal source still fires.
    static func install() {
        _ = storage  // initialised before any signal can arrive
        var action = sigaction()
        action.__sigaction_u.__sa_sigaction = { _, info, _ in
            TerminationSignalSender.storage.pointee = info?.pointee.si_pid ?? 0
        }
        action.sa_flags = SA_SIGINFO
        sigemptyset(&action.sa_mask)
        sigaction(SIGTERM, &action, nil)
    }

    /// The last sender, then forgotten. nil when unknown.
    static func take() -> Int32? {
        let pid = storage.pointee
        storage.pointee = 0
        return pid > 0 ? pid : nil
    }
}

/// SMAppService agent client. Every SMAppService and XPC call runs on its own serial queue.
@MainActor final class GoalongGuardClient: GoalongGuardClienting {
    static let registeredBuildKey = "goalong.guard.registeredBuild"
    static let reregisteredBuildKey = "goalong.guard.reregisteredBuild"
    nonisolated static let pingTimeout: TimeInterval = 2
    static let pingInterval: TimeInterval = 30
    /// SIGSTOP check of the known guard pid while armed, on its own timer (cheap: one proc_pidinfo).
    nonisolated static let stopCheckInterval: TimeInterval = 2
    /// `launchctl kickstart` exit status when the label is not loaded: someone ran `launchctl bootout`.
    nonisolated static let launchctlServiceNotFound: Int32 = 113

    var onChange: (() -> Void)?
    private let identity: GuardIdentity
    private let service: SMAppService
    private let defaults: UserDefaults
    private let build: String
    private let overrideActive: @Sendable () -> Bool
    fileprivate nonisolated let guardExecutable: String
    fileprivate nonisolated let queue = DispatchQueue(label: "ai.goalong.guard-client", qos: .utility)
    private var status: SMAppService.Status?
    private var statusRead = Date.distantPast
    private var working = false
    private var armed = false
    private var lastPing = Date.distantPast
    private var component: BlockingProtectionState.Component = .notInstalled
    /// register() failed in this launch: no retry until the next launch (an unsigned copy would loop).
    private var registerFailed = false
    /// `launchctl kickstart` already ran for this arming.
    private var kickstartUsed = false
    /// A ping answered "not armed" once in this arming: one early retry, after the marker check.
    private var notArmedRetried = false
    /// Every 2 s while armed, independent of refresh (15 s apart when the Mac is idle).
    private var stopWatch: GuardPeriodicCheck!
    /// Guard pid from its last reply. Touched on `queue` only.
    fileprivate nonisolated(unsafe) var guardPID: Int32?
    /// Kept open while armed: its interruption (the guard died) asks for a new ping. Touched on `queue` only.
    private nonisolated(unsafe) var connection: xpc_connection_t?

    /// nil outside an installed copy (`GoalongGuardGate`): the controller then has no guard at all.
    static func standard(defaults: UserDefaults = .standard) -> GoalongGuardClient? {
        guard GoalongGuardGate.isAllowed, let identity = GoalongGuardGate.identity else { return nil }
        return GoalongGuardClient(identity: identity, defaults: defaults)
    }

    init(identity: GuardIdentity, defaults: UserDefaults,
         overrideActive: @escaping @Sendable () -> Bool = { GoalongGuardFiles.overrideActive() }) {
        self.identity = identity
        service = SMAppService.agent(plistName: identity.plistName)
        self.defaults = defaults
        self.overrideActive = overrideActive
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        guardExecutable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(GuardIdentity.executableName).path
        stopWatch = GuardPeriodicCheck(queue: queue, interval: Self.stopCheckInterval) { [weak self] in
            self?.resumeKnownGuardOnQueue()
        }
        readStatus()
    }

    /// The 2 s SIGSTOP check runs exactly while armed and no installer override is active.
    var isWatchingForStop: Bool { stopWatch.isActive }

    var needsConsent: Bool {
        if let status { return status == .notRegistered || status == .notFound }
        return defaults.string(forKey: Self.registeredBuildKey) == nil
    }
    var canRemove: Bool { status == .enabled || status == .requiresApproval }

    func update(severeUntil: Date?) -> BlockingProtectionState.Component {
        let wasArmed = armed
        armed = severeUntil != nil
        guard armed else {
            stopWatch.setActive(false)
            // Spec §3.4 "nil : rien": no BTM call while idle. One status read when a block ends, so the
            // "remove the service" button sees the current state; otherwise only the read at launch.
            if Self.readsStatusWhenIdle(wasArmed: wasArmed) { closeConnection(); readStatus() }
            component = .notInstalled
            return component
        }
        if !wasArmed { lastPing = .distantPast; kickstartUsed = false; notArmedRetried = false }
        if overrideActive() {
            // An installer is replacing or removing this copy with the override: never bring the guard back.
            stopWatch.setActive(false)
            component = .notInstalled
            return component
        }
        stopWatch.setActive(true)
        guard !working else { return component }
        switch status {
        case nil:
            readStatus()
        case .notRegistered?, .notFound?:
            // The only system notification: the first registration of this build's guard. Tried once per
            // launch when it fails (unsigned or unnotarised copy), never on every refresh.
            guard !registerFailed else { component = .failed("Service de protection indisponible."); break }
            component = .notInstalled
            work { client in client.registerThenPing() }
        case .requiresApproval?:
            component = .awaitingApproval
            if Date().timeIntervalSince(statusRead) > Self.pingInterval { readStatus() }
        case .enabled?:
            if Date().timeIntervalSince(lastPing) >= Self.pingInterval {
                lastPing = Date()
                work { client in client.pingEscalating() }
            }
        @unknown default:
            component = .failed("Service de protection indisponible.")
        }
        return component
    }

    func removeService() {
        guard !armed else { return }
        closeConnection()
        defaults.removeObject(forKey: Self.registeredBuildKey)
        let service = service
        working = true
        queue.async { [weak self] in
            try? service.unregister()
            let next = service.status
            DispatchQueue.main.async { self?.finish(status: next, component: .notInstalled) }
        }
    }

    /// Outside a severe block the status is read only once, when the block ends.
    nonisolated static func readsStatusWhenIdle(wasArmed: Bool) -> Bool { wasArmed }

    /// Re-register only when `launchctl kickstart` ran in this round and found the job loaded. A job
    /// missing from launchd while BTM says `.enabled` was removed by `launchctl bootout`: an exit the
    /// spec offers (§7), never undone here.
    nonisolated static func mayReregister(kickstartStatus: Int32?) -> Bool {
        guard let kickstartStatus else { return false }
        return kickstartStatus != launchctlServiceNotFound
    }

    /// SIGCONT to every stopped pid of the list. True when one was resumed.
    nonisolated static func resumeStopped(_ pids: [Int32], isStopped: (Int32) -> Bool = GuardProcesses.isStopped,
                                          resume: (Int32) -> Void = { _ = kill($0, SIGCONT) }) -> Bool {
        var resumed = false
        for pid in pids where pid > 0 && isStopped(pid) { resume(pid); resumed = true }
        return resumed
    }

    /// A remembered pid may have been reused: signal it only while it still runs this guard executable.
    nonisolated static func isGuardProcess(_ pid: Int32, executable: String,
                                           path: (Int32) -> String? = GuardProcesses.path(of:)) -> Bool {
        guard let actual = path(pid) else { return false }
        return actual == executable || actual == URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    }

    // MARK: Work off the main thread

    /// Cheap check of the known guard pid. Runs on `queue` only (the 2 s timer while armed).
    private nonisolated func resumeKnownGuardOnQueue() {
        guard let pid = guardPID, Self.isGuardProcess(pid, executable: guardExecutable) else { return }
        if Self.resumeStopped([pid]) { NSLog("Goalong: blocking guard was stopped, resumed") }
    }

    fileprivate enum Outcome { case running, unreachable, notArmed }

    private func readStatus() {
        guard !working else { return }
        working = true
        let service = service
        queue.async { [weak self] in
            let next = service.status
            DispatchQueue.main.async {
                guard let self else { return }
                self.finish(status: next, component: self.component)
            }
        }
    }

    private func work(_ job: @escaping @Sendable (Worker) -> (SMAppService.Status, BlockingProtectionState.Component)) {
        working = true
        let worker = Worker(service: service, label: identity.label, client: self, overrideActive: overrideActive)
        queue.async { [weak self] in
            let (next, component) = job(worker)
            DispatchQueue.main.async { self?.finish(status: next, component: component) }
        }
    }

    private func finish(status next: SMAppService.Status, component next2: BlockingProtectionState.Component) {
        working = false
        let changed = status != next || component != next2
        status = next; statusRead = Date(); component = armed ? next2 : .notInstalled
        if next == .enabled, defaults.string(forKey: Self.registeredBuildKey) == nil { defaults.set(build, forKey: Self.registeredBuildKey) }
        if changed { onChange?() }
    }

    private func closeConnection() {
        queue.async { [weak self] in
            if let connection = self?.connection { xpc_connection_cancel(connection) }
            self?.connection = nil
        }
    }

    /// Re-register at most once per build: an unregister/register pair may show the notification again.
    fileprivate func claimReregister() -> Bool {
        guard defaults.string(forKey: Self.reregisteredBuildKey) != build else { return false }
        defaults.set(build, forKey: Self.reregisteredBuildKey)
        return true
    }

    /// `launchctl kickstart` at most once per arming (spec §3.4): later rounds only ping.
    fileprivate func claimKickstart() -> Bool {
        guard armed, !kickstartUsed else { return false }
        kickstartUsed = true
        return true
    }

    fileprivate func noteRegisterFailed() { registerFailed = true }

    /// The guard answered but does not see the block (marker forged or not yet written): the controller
    /// has rewritten the marker before this update, so ping once more soon instead of in 30 s.
    fileprivate func noteNotArmed() {
        guard armed, !notArmedRetried else { return }
        notArmedRetried = true
        lastPing = Date().addingTimeInterval(-Self.pingInterval + 3)
    }

    fileprivate func connectionLost() {
        guard armed else { return }
        lastPing = .distantPast
        onChange?()
    }

    /// Runs on `queue` only.
    fileprivate struct Worker: @unchecked Sendable {
        let service: SMAppService
        let label: String
        weak var client: GoalongGuardClient?
        let overrideActive: @Sendable () -> Bool

        func registerThenPing() -> (SMAppService.Status, BlockingProtectionState.Component) {
            try? service.register()
            let status = service.status
            switch status {
            case .enabled: return pingEscalating()
            case .requiresApproval: return (status, .awaitingApproval)
            default:
                DispatchQueue.main.async { MainActor.assumeIsolated { client?.noteRegisterFailed() } }
                return (status, .failed("Service de protection indisponible."))
            }
        }

        /// Status first: an intentional unregister or a switch-off in Login Items is never undone here.
        /// Then ping → resume a stopped guard → kickstart once per arming → re-register once per build →
        /// failed. Never an alert.
        func pingEscalating() -> (SMAppService.Status, BlockingProtectionState.Component) {
            let status = service.status
            switch status {
            case .enabled: break
            case .requiresApproval: return (status, .awaitingApproval)
            default: return (status, .notInstalled)
            }
            switch ping() {
            case .running: return (.enabled, .running)
            case .notArmed:
                DispatchQueue.main.async { MainActor.assumeIsolated { client?.noteNotArmed() } }
                return (.enabled, .failed("Le service de protection ne voit pas le blocage."))
            case .unreachable: break
            }
            // A SIGSTOPped guard looks alive to launchd, so nothing else would ever restart it.
            if resumeStoppedGuards(), ping() == .running { return (.enabled, .running) }
            guard !overrideActive() else { return (.enabled, .notInstalled) }
            let mayKickstart = DispatchQueue.main.sync { MainActor.assumeIsolated { client?.claimKickstart() ?? false } }
            var kickstartStatus: Int32?
            if mayKickstart {
                kickstartStatus = kickstart()
                if ping() == .running { return (.enabled, .running) }
            }
            guard GoalongGuardClient.mayReregister(kickstartStatus: kickstartStatus) else {
                if kickstartStatus == GoalongGuardClient.launchctlServiceNotFound {
                    return (.enabled, .failed("Service de protection arrêté jusqu’à la prochaine ouverture de session."))
                }
                return (service.status, .failed("Service de protection injoignable."))
            }
            let allowed = !overrideActive() && DispatchQueue.main.sync { MainActor.assumeIsolated { client?.claimReregister() ?? false } }
            if allowed {
                try? service.unregister()
                Thread.sleep(forTimeInterval: 1)
                try? service.register()
                let status = service.status
                if status == .requiresApproval { return (status, .awaitingApproval) }
                if status == .enabled, ping() == .running { return (status, .running) }
            }
            return (service.status, .failed("Service de protection injoignable."))
        }

        func ping() -> Outcome {
            guard let client else { return .unreachable }
            let connection: xpc_connection_t = client.connection ?? {
                let value = xpc_connection_create_mach_service(label, DispatchQueue.global(qos: .utility), 0)
                let queue = client.queue
                xpc_connection_set_event_handler(value) { [weak client] event in
                    guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
                    queue.async {
                        guard let client, client.connection === value else { return }
                        client.connection = nil
                        DispatchQueue.main.async { MainActor.assumeIsolated { client.connectionLost() } }
                    }
                }
                xpc_connection_resume(value)
                client.connection = value
                return value
            }()
            if let pid = client.guardPID, GoalongGuardClient.isGuardProcess(pid, executable: client.guardExecutable) {
                _ = GoalongGuardClient.resumeStopped([pid])
            }
            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(message, "ping", "goalong")
            let done = DispatchSemaphore(value: 0)
            let result = Box()
            xpc_connection_send_message_with_reply(connection, message, DispatchQueue.global(qos: .utility)) { reply in
                if xpc_get_type(reply) == XPC_TYPE_DICTIONARY {
                    result.value = xpc_dictionary_get_bool(reply, "armed") ? .running : .notArmed
                    let pid = xpc_dictionary_get_int64(reply, "pid")
                    result.pid = pid > 0 && pid <= Int64(Int32.max) ? Int32(pid) : nil
                }
                done.signal()
            }
            guard done.wait(timeout: .now() + GoalongGuardClient.pingTimeout) == .success, let value = result.value else {
                xpc_connection_cancel(connection)
                if client.connection === connection { client.connection = nil }
                return .unreachable
            }
            if let pid = result.pid { client.guardPID = pid }
            return value
        }

        /// After a ping timeout: every process of this bundle's guard executable, by exact path.
        func resumeStoppedGuards() -> Bool {
            guard let client else { return false }
            return GoalongGuardClient.resumeStopped(GuardProcesses.pids(executable: client.guardExecutable))
        }

        /// `launchctl kickstart` without `-k`: starts the agent if launchd holds it stopped, never kills it.
        /// Returns launchctl's exit status (113: the label is not loaded), nil when it could not run.
        func kickstart() -> Int32? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            process.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.5)
            return process.terminationStatus
        }

        final class Box: @unchecked Sendable { var value: Outcome?; var pid: Int32? }
    }
}
#endif
