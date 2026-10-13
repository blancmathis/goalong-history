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
guard CommandLine.arguments.count == 4 else {
    fail("Usage: dev-app-control quit-all|quit-dev|launch|status APP OTHER_APP | badge-icon IN OUT | seed-data REAL DEV")
}

/// The DEV bundle icon: the release icon with an orange "DEV" band (Dock, Cmd-Tab, Finder, notifications).
func badgeIcon(_ input: String, _ output: String) {
    guard let source = NSImage(contentsOfFile: input),
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB) else { fail("Cannot read icon: \(input)") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    source.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    // Clip to the icon's rounded square (Distribution/AppIcon.png: 844 px at x 90, y 102).
    NSBezierPath(roundedRect: NSRect(x: 90, y: 102, width: 844, height: 844), xRadius: 212, yRadius: 212).addClip()
    let band = NSRect(x: 0, y: 150, width: 1024, height: 205)
    NSColor(srgbRed: 1.0, green: 0.584, blue: 0.0, alpha: 1).setFill()
    band.fill()
    let text = NSAttributedString(string: "DEV", attributes: [
        .font: NSFont.systemFont(ofSize: 165, weight: .heavy), .kern: 14,
        .foregroundColor: NSColor(srgbRed: 0.094, green: 0.129, blue: 0.051, alpha: 1)])
    let size = text.size()
    text.draw(at: NSPoint(x: (1024 - size.width) / 2 + 7, y: band.midY - size.height / 2))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]),
          (try? png.write(to: URL(fileURLWithPath: output), options: .atomic)) != nil else { fail("Cannot write icon: \(output)") }
    exit(0)
}

/// Re-seeds LocalHistory-Dev from LocalHistory with APFS clones (instant, no extra disk).
/// Blocking and Focus stay in the real folder (the dev copy uses them there); backups and sockets are skipped.
func seedData(_ realPath: String, _ devPath: String) {
    let fileManager = FileManager.default
    let real = URL(fileURLWithPath: realPath).standardizedFileURL, dev = URL(fileURLWithPath: devPath).standardizedFileURL
    guard real.lastPathComponent == "LocalHistory", dev.lastPathComponent == "LocalHistory-Dev",
          real.deletingLastPathComponent() == dev.deletingLastPathComponent() else { fail("Refusing seed paths: \(realPath) -> \(devPath)") }
    var info = stat()
    guard lstat(real.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { fail("Real data folder is missing or redirected: \(real.path)") }
    if lstat(dev.path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFDIR else { fail("Dev data folder is not a plain folder: \(dev.path)") }
        do { try fileManager.removeItem(at: dev) } catch { fail("Cannot remove the previous dev data: \(error.localizedDescription)") }
    }
    guard mkdir(dev.path, 0o700) == 0 else { fail("Cannot create \(dev.path): \(String(cString: strerror(errno)))") }
    let skipped: Set<String> = ["Blocking", "Focus", "app-backups", "setup-backups", "runtime"]
    let names: [String]
    do { names = try fileManager.contentsOfDirectory(atPath: real.path) } catch { fail("Cannot list \(real.path)") }
    for name in names.sorted() where !skipped.contains(name) {
        let source = real.appendingPathComponent(name).path, target = dev.appendingPathComponent(name).path
        guard clonefile(source, target, UInt32(CLONE_NOFOLLOW)) == 0 else {
            fail("APFS clone failed for \(name): \(String(cString: strerror(errno))). No full copy was attempted.")
        }
    }
    print("Dev data re-seeded by APFS clone: \(dev.path)")
    exit(0)
}
switch CommandLine.arguments[1] {
case "badge-icon": badgeIcon(CommandLine.arguments[2], CommandLine.arguments[3])
case "seed-data": seedData(CommandLine.arguments[2], CommandLine.arguments[3])
default: break
}
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
