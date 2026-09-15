#if os(macOS)
import AppKit
import Darwin
import Foundation
import MachO

// One-shot, non-UI helper. No history access, permission API, shell or arbitrary target.
// It registers for the exact parent's exit BEFORE acknowledging readiness.
let args = CommandLine.arguments
guard args.count == 5, args[1] == "--parent", args[3] == "--launched",
      let parentPID = Int32(args[2]), parentPID > 1, getppid() == parentPID,
      let launched = TimeInterval(args[4]), launched.isFinite else { exit(64) }
var executableSize: UInt32 = 0
_NSGetExecutablePath(nil, &executableSize)
var executableBuffer = [CChar](repeating: 0, count: Int(executableSize))
guard _NSGetExecutablePath(&executableBuffer, &executableSize) == 0 else { exit(65) }
let executable = URL(fileURLWithPath: String(cString: executableBuffer)).resolvingSymlinksInPath()
let appURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
guard executable.lastPathComponent == "goalong-relauncher",
      executable.deletingLastPathComponent().lastPathComponent == "MacOS",
      appURL.pathExtension == "app",
      Bundle(url: appURL)?.bundleIdentifier == "ai.goalong.localhistory",
      let parent = NSRunningApplication(processIdentifier: parentPID), !parent.isTerminated,
      parent.bundleURL?.resolvingSymlinksInPath() == appURL,
      let launchDate = parent.launchDate,
      abs(launchDate.timeIntervalSince1970 - launched) < 0.01 else { exit(66) }
// Detach from the old application's session where possible. Never register as an NSApplication.
_ = setsid()
let timeout = DispatchWorkItem { exit(70) }
DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
let exitWatch = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .main)
func reopen(attempt: Int) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    // macOS may also reopen after its permission prompt. Reuse that copy, never start two recorders.
    configuration.createsNewApplicationInstance = false
    configuration.arguments = ["--permission-recovery-complete"]
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
        DispatchQueue.main.async {
            if error == nil, let app, !app.isTerminated, app.processIdentifier != parentPID {
                // LaunchServices acknowledgement alone is not proof that the reopened app survived startup.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if !app.isTerminated { exit(0) }
                    guard attempt < 3 else { exit(71) }
                    reopen(attempt: attempt + 1)
                }
            } else {
                guard attempt < 3 else { exit(71) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { reopen(attempt: attempt + 1) }
            }
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
