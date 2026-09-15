#if os(macOS)
    import AppKit
    import Foundation
    import SwiftUI

    /// Recovery never changes TCC, code signatures, saved consent, or recording choices.
    /// LaunchServices relaunches only this exact bundle; the new process waits for
    /// the old one to flush and exit before opening any history stores.
    enum PermissionRecovery {
        static let parentArgument = "--permission-recovery-parent"
        static let parentLaunchArgument = "--permission-recovery-parent-launched"

        enum ParentState: Equatable { case notRequested, ready, waiting, invalid }

        static func parentState(arguments: [String], currentPID: Int32, bundleURL: URL,
                                lookup: (Int32) -> (URL, Date?)?) -> ParentState {
            guard let index = arguments.firstIndex(of: parentArgument) else { return .notRequested }
            guard arguments.indices.contains(index + 1),
                  let pid = Int32(arguments[index + 1]), pid > 1, pid != currentPID,
                  let launchIndex = arguments.firstIndex(of: parentLaunchArgument),
                  arguments.indices.contains(launchIndex + 1),
                  let launched = TimeInterval(arguments[launchIndex + 1]), launched.isFinite else { return .invalid }
            guard let (parentURL, launchDate) = lookup(pid) else { return .ready }
            guard parentURL.standardizedFileURL == bundleURL.standardizedFileURL,
                  let launchDate,
                  abs(launchDate.timeIntervalSince1970 - launched) < 0.01 else { return .invalid }
            return .waiting
        }

        @MainActor static func launchWhenParentHasExited(_ start: @escaping @MainActor () -> Void) {
            let deadline = Date().addingTimeInterval(20)
            func check() {
                let state = parentState(arguments: CommandLine.arguments,
                                        currentPID: ProcessInfo.processInfo.processIdentifier,
                                        bundleURL: Bundle.main.bundleURL) { pid in
                    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                          let url = app.bundleURL else { return nil }
                    return (url, app.launchDate)
                }
                switch state {
                case .notRequested, .ready: start()
                case .waiting where Date() < deadline:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
                case .waiting, .invalid:
                    // Never kill a process or open the same stores concurrently.
                    NSApplication.shared.terminate(nil)
                }
            }
            check()
        }

        static let completedArgument = "--permission-recovery-complete"
        private static let returnKey = "goalong.permissions.returnToSetup.v2"
        @MainActor static var resumedCapability: GoalongCapability?
        @MainActor private static var relaunch: PermissionRelaunchHandshake?
        @MainActor static var isRestarting: Bool { relaunch != nil }

        static func rememberSetup(_ capability: GoalongCapability, defaults: UserDefaults = .standard, now: Date = Date()) {
            guard [.localComputerHistory, .appleScreenTime, .aiConversations].contains(capability) else { return }
            defaults.set(["capability": capability.rawValue, "expires": now.addingTimeInterval(600).timeIntervalSince1970], forKey: returnKey)
        }

        static func pendingSetup(defaults: UserDefaults = .standard, now: Date = Date()) -> GoalongCapability? {
            guard let value = defaults.dictionary(forKey: returnKey),
                  let raw = value["capability"] as? String, let capability = GoalongCapability(rawValue: raw),
                  [.localComputerHistory, .appleScreenTime, .aiConversations].contains(capability),
                  let expiry = value["expires"] as? Double, expiry.isFinite,
                  expiry > now.timeIntervalSince1970, expiry <= now.addingTimeInterval(600).timeIntervalSince1970 else { return nil }
            return capability
        }

        static func clearSetup(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: returnKey) }

        @MainActor static func consumeSetupReturn() -> Bool {
            resumedCapability = pendingSetup()
            clearSetup()
            return resumedCapability != nil
        }

        @MainActor static func takeSetupReturn(for capability: GoalongCapability) -> Bool {
            guard resumedCapability == capability else { return false }
            resumedCapability = nil
            return true
        }

        static func shouldAssistSettingsQuit(senderBundleID: String?, pendingSetup: Bool, alreadyRestarting: Bool) -> Bool {
            pendingSetup && !alreadyRestarting && senderBundleID == "com.apple.systempreferences"
        }

        @MainActor static func prepareRelaunch(completion: @escaping (String?) -> Void) {
            guard relaunch == nil else { completion("Goalong is already preparing to reopen."); return }
            let handshake = PermissionRelaunchHandshake()
            relaunch = handshake
            handshake.start { error in
                if error != nil { relaunch = nil }
                completion(error)
            }
        }

        @MainActor static func restart(completion: @escaping (String?) -> Void) {
            prepareRelaunch { error in
                completion(error)
                guard error == nil else { return }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// The parent stays alive until its bundled, fixed-purpose helper is listening for its exit.
    /// Failure cancels only that owned helper, not Goalong or another application.
    @MainActor private final class PermissionRelaunchHandshake {
        private var process: Process?
        private var pipe: Pipe?
        private var timeout: DispatchWorkItem?
        private var finished = false
        private var received = Data()

        func start(completion: @escaping (String?) -> Void) {
            let bundle = Bundle.main
            let helper = bundle.bundleURL.resolvingSymlinksInPath().appendingPathComponent("Contents/MacOS/goalong-relauncher")
            guard bundle.bundleURL.pathExtension == "app", bundle.bundleIdentifier == "ai.goalong.localhistory",
                  helper.resolvingSymlinksInPath() == helper.standardizedFileURL,
                  FileManager.default.isExecutableFile(atPath: helper.path),
                  let launched = NSRunningApplication.current.launchDate else {
                completion("The restart component is unavailable. Goalong has stayed open; install the latest update and try again.")
                return
            }
            let child = Process()
            child.executableURL = helper
            child.arguments = ["--parent", String(ProcessInfo.processInfo.processIdentifier),
                               "--launched", String(launched.timeIntervalSince1970)]
            let inherited = ProcessInfo.processInfo.environment
            child.environment = inherited.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"].contains($0.key) }
            child.standardInput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            let output = Pipe()
            child.standardOutput = output
            pipe = output; process = child
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                DispatchQueue.main.async {
                    guard let self, !self.finished else { return }
                    self.received.append(bytes)
                    if self.received == Data("READY\n".utf8) {
                        self.finish(error: nil, completion: completion)
                    } else if bytes.isEmpty || self.received.count > 32 {
                        self.finish(error: "Restart could not be prepared. Goalong has stayed open. Please try again.", completion: completion)
                    }
                }
            }
            let deadline = DispatchWorkItem { [weak self] in
                self?.finish(error: "The restart component did not respond. Goalong has stayed open. Please try again.", completion: completion)
            }
            timeout = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
            do { try child.run() }
            catch { finish(error: "Restart could not be prepared: \(error.localizedDescription)", completion: completion) }
        }

        private func finish(error: String?, completion: (String?) -> Void) {
            guard !finished else { return }
            finished = true
            timeout?.cancel(); timeout = nil
            pipe?.fileHandleForReading.readabilityHandler = nil
            if error != nil, let process, process.isRunning { process.terminate() }
            completion(error)
        }
    }
#endif
