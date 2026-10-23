#if os(macOS)
import AppKit
import Darwin
import Foundation
import GoalongGuardCore
import MachO
import os
import Security
import XPC

// Blocking guard: a launchd user agent (SMAppService, no root, no UI). It acts only while its own
// copy's `Blocking/guard-until` is in the future, and only on its own app. Otherwise it exits 0 at once
// and launchd (KeepAlive SuccessfulExit=false) leaves it stopped.
var executableSize: UInt32 = 0
_NSGetExecutablePath(nil, &executableSize)
var executableBuffer = [CChar](repeating: 0, count: Int(executableSize))
guard _NSGetExecutablePath(&executableBuffer, &executableSize) == 0 else { exit(0) }
let executable = URL(fileURLWithPath: String(cString: executableBuffer)).resolvingSymlinksInPath()
guard let bundle = GuardBundle(guardExecutable: executable) else { exit(0) }
let identity = bundle.identity
let logger = Logger(subsystem: identity.logSubsystem, category: "guard")
let files = GuardFiles(directory: identity.blockingDirectory(base: GuardIdentity.applicationSupportBase))

func fileStamp(_ url: URL) -> (ino_t, Int, Int)? {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return nil }
    return (info.st_ino, info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec)
}
let ownStamp = fileStamp(executable)
let build = (NSDictionary(contentsOf: bundle.infoPlist)?["CFBundleVersion"] as? String) ?? "unknown"

var environment = GuardEnvironment(
    locateApp: { GuardProcesses.pids(executable: bundle.appExecutable.path).first },
    launch: { completion in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        configuration.arguments = [GuardIdentity.relaunchArgument]
        // Always the URL of the bundle that contains this guard, never a bundle id.
        NSWorkspace.shared.openApplication(at: bundle.appURL, configuration: configuration) { app, error in
            completion(app.map { $0.isTerminated ? -1 : $0.processIdentifier }, error)
        }
    })
environment.proofAlive = { reason in
    guard let path = bundle.proofPath(for: reason) else { return false }
    return !GuardProcesses.pids(executable: path).isEmpty
}
environment.bundlePresent = { FileManager.default.fileExists(atPath: bundle.infoPlist.path) }
environment.binaryReplaced = {
    guard let ownStamp, let now = fileStamp(executable) else { return false }
    return now != ownStamp
}
environment.log = { message in logger.log("\(message, privacy: .public)") }
environment.build = build

let engine = GuardEngine(files: files, environment: environment, queue: .main) { code in
    logger.log("guard exits with \(code)")
    // A ping that woke this guard is answered first ("not armed"), so the app does not escalate.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(code) }
}

// Wake-up channel. A message is only a ping: the guard decides from its own files, never from a request.
let listener = xpc_connection_create_mach_service(identity.machServiceName, DispatchQueue.main,
                                                  UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
let peerRequirement: String = {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var information: CFDictionary?
    if SecCodeCopySelf([], &code) == errSecSuccess, let code,
       SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
       SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
       let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identity.bundleIdentifier)\""
    }
    // Ad-hoc development build: no team. The channel carries no order, so the identifier is enough.
    return "identifier \"\(identity.bundleIdentifier)\""
}()
xpc_connection_set_event_handler(listener) { peer in
    guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
    if #available(macOS 12.0, *) {
        guard xpc_connection_set_peer_code_signing_requirement(peer, peerRequirement) == 0 else { xpc_connection_cancel(peer); return }
    }
    xpc_connection_set_event_handler(peer) { message in
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
        engine.poke()
        guard let reply = xpc_dictionary_create_reply(message) else { return }
        engine.snapshot { snapshot in
            xpc_dictionary_set_string(reply, "build", snapshot.build)
            xpc_dictionary_set_bool(reply, "armed", snapshot.armed)
            xpc_dictionary_set_int64(reply, "watchingPID", Int64(snapshot.watchingPID ?? 0))
            xpc_dictionary_set_string(reply, "state", snapshot.state)
            // Lets the app notice a SIGSTOP of this guard and resume it (launchd only sees a live job).
            xpc_dictionary_set_int64(reply, "pid", Int64(getpid()))
            xpc_connection_send_message(peer, reply)
        }
    }
    xpc_connection_resume(peer)
}
xpc_connection_resume(listener)

let launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
) { note in
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    if app?.bundleURL?.resolvingSymlinksInPath() == bundle.appURL { engine.poke() }
}
engine.start()
// NSWorkspace needs the main run loop. No NSApplication, no window, no Dock icon.
RunLoop.main.run()
_ = launchObserver
#else
import Foundation
exit(0)
#endif
