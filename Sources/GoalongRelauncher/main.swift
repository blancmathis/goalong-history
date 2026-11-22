#if os(macOS)
import AppKit
import Darwin
import Foundation
import GoalongGuardCore
import MachO

// One-shot, non-UI helper. No history access, permission API, shell or arbitrary target.
// It registers for the exact parent's exit BEFORE acknowledging readiness.
// Perso builds also accept `--perso-swap <id>`: started from a staged update beside the installed app, it
// reopens the installed path after the parent quits and rolls the swap back unless the new app reports health.
let args = CommandLine.arguments
var persoRequest: String?
#if GOALONG_PERSO
if args.count == 7, args[5] == "--perso-swap", PersoUpdate.isValidRequestID(args[6]) { persoRequest = args[6] }
#endif
guard args.count == 5 || persoRequest != nil, args[1] == "--parent", args[3] == "--launched",
      let parentPID = Int32(args[2]), parentPID > 1, getppid() == parentPID,
      let launched = TimeInterval(args[4]), launched.isFinite else { exit(64) }
var executableSize: UInt32 = 0
_NSGetExecutablePath(nil, &executableSize)
var executableBuffer = [CChar](repeating: 0, count: Int(executableSize))
guard _NSGetExecutablePath(&executableBuffer, &executableSize) == 0 else { exit(65) }
let executable = URL(fileURLWithPath: String(cString: executableBuffer)).resolvingSymlinksInPath()
let ownApp = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
// A perso swap reopens the installed path that the staged copy replaces; otherwise our own bundle.
let persoTarget = persoRequest.flatMap { PersoStage.target(forStaged: ownApp, request: $0) }
guard persoRequest == nil || persoTarget != nil else { exit(66) }
let appURL = persoTarget ?? ownApp
let persoBuiltAt = PersoBundleFacts.read(app: ownApp).builtAt
guard executable.lastPathComponent == "goalong-relauncher",
      executable.deletingLastPathComponent().lastPathComponent == "MacOS",
      appURL.pathExtension == "app",
      ["ai.goalong.localhistory", "ai.goalong.localhistory.dev"].contains(Bundle(url: appURL)?.bundleIdentifier ?? ""),
      persoRequest == nil || Bundle(url: ownApp)?.bundleIdentifier == Bundle(url: appURL)?.bundleIdentifier,
      let parent = NSRunningApplication(processIdentifier: parentPID), !parent.isTerminated,
      parent.bundleURL?.resolvingSymlinksInPath() == appURL,
      let launchDate = parent.launchDate,
      abs(launchDate.timeIntervalSince1970 - launched) < 0.01 else { exit(66) }
// Detach from the old application's session where possible. Never register as an NSApplication.
_ = setsid()
let persoFiles = PersoUpdateFiles.standard
/// Puts the old app back, reopens it in the background and reports. Called once at most.
func persoRollBack(_ reason: String, newApp: NSRunningApplication?) -> Never {
    guard let request = persoRequest, let target = persoTarget else { exit(72) }
    if let newApp, !newApp.isTerminated {
        // A normal quit could ask for the blocking password; the old app comes straight back.
        newApp.forceTerminate()
        let until = Date().addingTimeInterval(5)
        while !newApp.isTerminated, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let staged = PersoStage.stagedApp(for: target, request: request)
    let restored = (try? PersoSwapFinish.finish(target: target, staged: staged, healthy: false)) != nil
    if restored {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 10)
    }
    persoFiles.writeResult(request, .init(state: PersoUpdateFiles.Result.rolledBack,
                                          reason: restored ? reason : reason + " ; retour arrière impossible"))
    exit(73)
}
let timeout = DispatchWorkItem {
    // The perso parent never quit: its bundle was swapped under it, so put it back.
    if persoRequest != nil, !parent.isTerminated { persoRollBack("Goalong n’a pas quitté", newApp: nil) }
    exit(70)
}
DispatchQueue.main.asyncAfter(deadline: .now() + (persoRequest == nil ? 45 : 120), execute: timeout)
let exitWatch = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .main)
/// The new app proves it started by writing its pid and build time; otherwise roll back.
func awaitPersoHealth(_ app: NSRunningApplication, deadline: Date) {
    guard let request = persoRequest, let target = persoTarget else { exit(0) }
    if persoFiles.healthMatches(pid: app.processIdentifier, builtAt: persoBuiltAt) {
        try? PersoSwapFinish.finish(target: target, staged: PersoStage.stagedApp(for: target, request: request), healthy: true)
        persoFiles.writeResult(request, .init(state: PersoUpdateFiles.Result.installed))
        exit(0)
    }
    if app.isTerminated { persoRollBack("la nouvelle version s’est arrêtée au démarrage", newApp: nil) }
    if Date() >= deadline { persoRollBack("la nouvelle version n’a pas confirmé son démarrage", newApp: app) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { awaitPersoHealth(app, deadline: deadline) }
}
func reopen(attempt: Int) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = persoRequest == nil
    // macOS may also reopen after its permission prompt. Reuse that copy, never start two recorders.
    configuration.createsNewApplicationInstance = false
    configuration.arguments = persoRequest == nil ? ["--permission-recovery-complete"] : []
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
        DispatchQueue.main.async {
            // A successful launch ends our responsibility. Never resurrect an app the
            // person immediately quits again; retries are only for failed launch requests.
            if error == nil, let app, !app.isTerminated, app.processIdentifier != parentPID {
                if persoRequest == nil { exit(0) }
                awaitPersoHealth(app, deadline: Date().addingTimeInterval(PersoUpdate.healthTimeout))
                return
            }
            guard attempt < 3 else {
                if persoRequest != nil { persoRollBack("la nouvelle version n’a pas pu être ouverte", newApp: nil) }
                exit(71)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { reopen(attempt: attempt + 1) }
        }
    }
}
exitWatch.setEventHandler {
    exitWatch.cancel()
    // Allow LaunchServices to retire the old registration, after actual process exit.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { reopen(attempt: 0) }
}
exitWatch.activate()
do { try FileHandle.standardOutput.write(contentsOf: Data("READY\n".utf8)) }
catch { exit(74) }
RunLoop.main.run()
#else
import Foundation
exit(1)
#endif
