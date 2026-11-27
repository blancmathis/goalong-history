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
/// Status only (T-057 idées 5 et 6): the phases Settings and `make perso` show; no decision reads it.
let persoHistory = PersoUpdateHistory.standard
let persoCommit = PersoBundleFacts.read(app: ownApp).commit
/// The guard of the installed copy: a perso swap holds its lease until health or rollback (installation-05).
let guardFiles: GuardFiles? = persoRequest == nil ? nil : {
    let info = Bundle(url: appURL)?.infoDictionary
    guard let identity = GuardIdentity(bundleIdentifier: info?["CFBundleIdentifier"] as? String,
                                       channel: info?[GuardIdentity.channelKey] as? String) else { return nil }
    return GuardFiles(directory: identity.blockingDirectory(base: GuardIdentity.applicationSupportBase))
}()
func holdLease(pid: Int32) {
    guard let request = persoRequest else { return }
    guardFiles?.holdPersoLease(pid: pid, request: request, now: Date().timeIntervalSince1970) // wall: guard protocol (spec K §4, wall)
}
func endLease() {
    guard let request = persoRequest else { return }
    guardFiles?.removeLease(reason: GuardLease.persoUpdate, request: request)
}
/// One deadline per phase (installation-04): the parent's quit deadline ends with the parent.
var timeline = RelauncherTimeline(perso: persoRequest != nil, now: GuardSystem.continuousSeconds())
/// Open requests still without an answer from LaunchServices (left on its own queue, never on main).
let pendingOpens = DispatchGroup()
/// Puts the old app back, reopens it in the background and reports. Called once at most (L1L2-03, L1L2-06).
func persoRollBack(_ reason: String, newApp: NSRunningApplication?) -> Never {
    timeline.finish()
    guard let request = persoRequest, let target = persoTarget else { exit(72) }
    let staged = PersoStage.stagedApp(for: target, request: request)
    let executableName = Bundle(url: target)?.infoDictionary?["CFBundleExecutable"] as? String ?? ""
    let targetExecutable = target.appendingPathComponent("Contents/MacOS/\(executableName)").path
    var rollback = PersoRollback(
        parentPID: parentPID,
        candidates: {
            var pids = executableName.isEmpty ? [] : GuardProcesses.pids(executable: targetExecutable)
            if let newApp, !pids.contains(newApp.processIdentifier) { pids.append(newApp.processIdentifier) }
            return pids
        },
        holdLease: { holdLease(pid: $0) },
        // A normal quit could ask for the blocking password; the old app comes straight back.
        terminate: { kill($0, SIGKILL) },
        isAlive: { GuardProcesses.isAlive($0) },
        restore: { (try? PersoSwapFinish.finish(target: target, staged: staged, healthy: false)) != nil },
        parentAlive: { GuardProcesses.isAlive(parentPID) },
        endLease: { endLease() },
        report: { restored in
            persoHistory.record(request, restored ? .restored : .failed, commit: persoCommit, reason: reason)
            persoFiles.writeResult(request, .init(state: PersoUpdateFiles.Result.rolledBack,
                                                  reason: restored ? reason : reason + " ; retour arrière impossible"))
        },
        open: {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.createsNewApplicationInstance = false
            let done = DispatchSemaphore(value: 0)
            var opened: Int32?
            NSWorkspace.shared.openApplication(at: target, configuration: configuration) { app, _ in
                if let app, !app.isTerminated { opened = app.processIdentifier }
                done.signal()
            }
            return done.wait(timeout: .now() + 10) == .success ? opened : nil
        })
    // A launch whose answer is late still creates its process: wait for it, then the scan stops it.
    rollback.settleOpen = { _ = pendingOpens.wait(timeout: .now() + 35) }
    _ = rollback.run()
    exit(73)
}
var openedApp: NSRunningApplication?
/// One check per 0.25 s: whichever phase runs, only its own deadline counts.
let ticker = DispatchSource.makeTimerSource(queue: .main)
ticker.schedule(deadline: .now() + 0.25, repeating: 0.25)
ticker.setEventHandler {
    let gone = parent.isTerminated || kill(parentPID, 0) != 0
    // An exit seen before its event arrives still starts the reopen, never a timeout.
    if gone, timeline.phase == .waitingForParent { parentGone(); return }
    switch timeline.expiry(now: GuardSystem.continuousSeconds(), parentGone: gone) {
    case nil:
        return
    case .parentDidNotQuit:
        // The perso parent never quit: its bundle was swapped under it, so put it back.
        if persoRequest != nil { persoRollBack("Goalong n’a pas quitté", newApp: nil) }
        exit(70)
    case .reopenTimedOut:
        if persoRequest != nil { persoRollBack("la nouvelle version n’a pas pu être ouverte à temps", newApp: openedApp) }
        exit(71)
    case .healthTimedOut:
        persoRollBack("la nouvelle version n’a pas confirmé son démarrage", newApp: openedApp)
    }
}
ticker.activate()
let exitWatch = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .main)
/// The new app proves it finished launching by writing its pid and build time; otherwise roll back.
func awaitPersoHealth(_ app: NSRunningApplication) {
    guard timeline.phase == .awaitingHealth else { return }
    guard let request = persoRequest, let target = persoTarget else { exit(0) }
    if persoFiles.healthMatches(pid: app.processIdentifier, builtAt: persoBuiltAt) {
        timeline.finish()
        try? PersoSwapFinish.finish(target: target, staged: PersoStage.stagedApp(for: target, request: request), healthy: true)
        endLease()
        persoHistory.record(request, .done, commit: persoCommit)
        persoFiles.writeResult(request, .init(state: PersoUpdateFiles.Result.installed))
        exit(0)
    }
    if app.isTerminated { persoRollBack("la nouvelle version s’est arrêtée au démarrage", newApp: nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { awaitPersoHealth(app) }
}
func reopen(attempt: Int) {
    guard timeline.phase == .reopening else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = persoRequest == nil
    // macOS may also reopen after its permission prompt. Reuse that copy, never start two recorders.
    configuration.createsNewApplicationInstance = false
    configuration.arguments = persoRequest == nil ? ["--permission-recovery-complete"] : []
    pendingOpens.enter()
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
        pendingOpens.leave()
        DispatchQueue.main.async {
            // A late answer after the reopen deadline: the rollback already decided.
            guard timeline.phase == .reopening else { return }
            // A successful launch ends our responsibility. Never resurrect an app the
            // person immediately quits again; retries are only for failed launch requests.
            if error == nil, let app, !app.isTerminated, app.processIdentifier != parentPID {
                timeline.appOpened(now: GuardSystem.continuousSeconds())
                if persoRequest == nil { exit(0) }
                openedApp = app
                holdLease(pid: app.processIdentifier)
                awaitPersoHealth(app)
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
func parentGone() {
    exitWatch.cancel()
    timeline.parentExited(now: GuardSystem.continuousSeconds())
    if let request = persoRequest { persoHistory.record(request, .relaunching, commit: persoCommit) }
    // Allow LaunchServices to retire the old registration, after actual process exit.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { reopen(attempt: 0) }
}
exitWatch.setEventHandler { if timeline.phase == .waitingForParent { parentGone() } }
exitWatch.activate()
do { try FileHandle.standardOutput.write(contentsOf: Data("READY\n".utf8)) }
catch { exit(74) }
RunLoop.main.run()
#else
import Foundation
exit(1)
#endif
