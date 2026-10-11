// AppKit process control avoids AppleScript automation/TCC and Launch Services' bundle-ID ambiguity.
import AppKit
import Foundation

let identifier = "ai.goalong.localhistory"
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
func instances() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { !$0.isTerminated }
}
func wait(seconds: TimeInterval, until predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !predicate(), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return predicate()
}
guard CommandLine.arguments.count == 4 else { fail("Usage: dev-app-control quit-all|quit-dev|launch|status APP OTHER_APP") }
let action = CommandLine.arguments[1]
let target = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
let other = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
let running = instances()
for app in running {
    guard let url = app.bundleURL?.standardizedFileURL, url == target || url == other else {
        fail("Another Goalong copy is running (PID \(app.processIdentifier)). Quit it normally before switching.")
    }
}

switch action {
case "quit-all", "quit-dev":
    let quitting = running.filter { action == "quit-all" || $0.bundleURL?.standardizedFileURL == target }
    for app in quitting {
        print("Quit requested: PID \(app.processIdentifier), \(app.bundleURL!.path)")
        guard app.terminate() else { fail("Goalong refused to quit. Resolve its active blocking/confirmation before retrying.") }
    }
    guard wait(seconds: 15, until: { quitting.allSatisfy(\.isTerminated) }) else {
        fail("Goalong did not quit within 15 s. Resolve its active blocking/confirmation before retrying; no forced termination was used.")
    }
case "launch":
    guard Bundle(url: target)?.bundleIdentifier == identifier else { fail("Invalid Goalong app: \(target.path)") }
    guard running.isEmpty || (running.count == 1 && running[0].bundleURL?.standardizedFileURL == target) else {
        fail("Another Goalong instance is still running; refusing a second instance.")
    }
    if let app = running.first {
        _ = app.activate(options: [.activateAllWindows])
    } else {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        var completed = false
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { _, error in
            launchError = error
            completed = true
        }
        guard wait(seconds: 15, until: { completed }) else { fail("Launch timed out: \(target.path)") }
        if let launchError { fail("Launch failed: \(launchError.localizedDescription)") }
    }
    guard wait(seconds: 15, until: {
        let apps = instances()
        return apps.count == 1 && apps[0].bundleURL?.standardizedFileURL == target && apps[0].isFinishedLaunching
    }) else { fail("Goalong did not finish launching from \(target.path).") }
    // Catch an immediate crash or the app's single-instance rejection after Launch Services responds.
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    let apps = instances()
    guard apps.count == 1, apps[0].bundleURL?.standardizedFileURL == target else {
        fail("Goalong exited or another instance appeared during launch.")
    }
    print("Running: PID \(apps[0].processIdentifier), \(target.path)")
case "status":
    print("Goalong instances: \(running.count)")
    for app in running { print("PID \(app.processIdentifier): \(app.bundleURL!.path)") }
default:
    fail("Unknown action: \(action)")
}
