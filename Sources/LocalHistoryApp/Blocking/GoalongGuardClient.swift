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

    /// Runs the command and exits. Never touches another copy's guard: the plist name is this bundle's own.
    static func run() -> Never {
        guard let identity = GoalongGuardGate.identity else { exit(0) }
        let files = GoalongGuardFiles.standard
        if isRefused(marker: files.readMarker(now: Date()), now: Date(), environment: ProcessInfo.processInfo.environment) {
            FileHandle.standardError.write(Data("Un blocage sévère est actif : le service de protection reste en place.\n".utf8))
            exit(refusedExitCode)
        }
        let service = SMAppService.agent(plistName: identity.plistName)
        if service.status != .notRegistered { try? service.unregister() }
        exit(0)
    }
}

/// SMAppService agent client. Every SMAppService and XPC call runs on its own serial queue.
@MainActor final class GoalongGuardClient: GoalongGuardClienting {
    static let registeredBuildKey = "goalong.guard.registeredBuild"
    static let reregisteredBuildKey = "goalong.guard.reregisteredBuild"
    nonisolated static let pingTimeout: TimeInterval = 2
    static let pingInterval: TimeInterval = 30

    var onChange: (() -> Void)?
    private let identity: GuardIdentity
    private let service: SMAppService
    private let defaults: UserDefaults
    private let build: String
    fileprivate nonisolated let queue = DispatchQueue(label: "ai.goalong.guard-client", qos: .utility)
    private var status: SMAppService.Status?
    private var statusRead = Date.distantPast
    private var working = false
    private var armed = false
    private var lastPing = Date.distantPast
    private var component: BlockingProtectionState.Component = .notInstalled
    /// Kept open while armed: its interruption (the guard died) asks for a new ping. Touched on `queue` only.
    private nonisolated(unsafe) var connection: xpc_connection_t?

    /// nil outside an installed copy (`GoalongGuardGate`): the controller then has no guard at all.
    static func standard(defaults: UserDefaults = .standard) -> GoalongGuardClient? {
        guard GoalongGuardGate.isAllowed, let identity = GoalongGuardGate.identity else { return nil }
        return GoalongGuardClient(identity: identity, defaults: defaults)
    }

    init(identity: GuardIdentity, defaults: UserDefaults) {
        self.identity = identity
        service = SMAppService.agent(plistName: identity.plistName)
        self.defaults = defaults
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        readStatus()
    }

    var needsConsent: Bool {
        if let status { return status == .notRegistered || status == .notFound }
        return defaults.string(forKey: Self.registeredBuildKey) == nil
    }
    var canRemove: Bool { status == .enabled || status == .requiresApproval }

    func update(severeUntil: Date?) -> BlockingProtectionState.Component {
        let wasArmed = armed
        armed = severeUntil != nil
        guard armed else {
            if wasArmed { closeConnection() }
            component = .notInstalled
            if Date().timeIntervalSince(statusRead) > Self.pingInterval { readStatus() }
            return component
        }
        if !wasArmed { lastPing = .distantPast }
        guard !working else { return component }
        switch status {
        case nil:
            readStatus()
        case .notRegistered?, .notFound?:
            // The only system notification: the first registration of this build's guard.
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

    // MARK: Work off the main thread

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
        let worker = Worker(service: service, label: identity.label, client: self)
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

        func registerThenPing() -> (SMAppService.Status, BlockingProtectionState.Component) {
            try? service.register()
            let status = service.status
            switch status {
            case .enabled: return pingEscalating()
            case .requiresApproval: return (status, .awaitingApproval)
            default: return (status, .failed("Service de protection indisponible."))
            }
        }

        /// Ping → kickstart once → re-register once per build → failed. Never an alert.
        func pingEscalating() -> (SMAppService.Status, BlockingProtectionState.Component) {
            switch ping() {
            case .running: return (.enabled, .running)
            case .notArmed: return (.enabled, .failed("Le service de protection ne voit pas le blocage."))
            case .unreachable: break
            }
            kickstart()
            if ping() == .running { return (.enabled, .running) }
            let allowed = DispatchQueue.main.sync { MainActor.assumeIsolated { client?.claimReregister() ?? false } }
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
            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(message, "ping", "goalong")
            let done = DispatchSemaphore(value: 0)
            let result = Box()
            xpc_connection_send_message_with_reply(connection, message, DispatchQueue.global(qos: .utility)) { reply in
                if xpc_get_type(reply) == XPC_TYPE_DICTIONARY {
                    result.value = xpc_dictionary_get_bool(reply, "armed") ? .running : .notArmed
                }
                done.signal()
            }
            guard done.wait(timeout: .now() + GoalongGuardClient.pingTimeout) == .success, let value = result.value else {
                xpc_connection_cancel(connection)
                if client.connection === connection { client.connection = nil }
                return .unreachable
            }
            return value
        }

        /// `launchctl kickstart` without `-k`: starts the agent if launchd holds it stopped, never kills it.
        func kickstart() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.5)
        }

        final class Box: @unchecked Sendable { var value: Outcome? }
    }
}
#endif
