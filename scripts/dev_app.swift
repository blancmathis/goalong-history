// make dev control for Goalong Dev. AppKit process control avoids AppleScript automation/TCC.
// It only ever acts on the bundle ID ai.goalong.localhistory.dev: the installed Goalong is never quit or launched.
import AppKit
import Foundation

let devIdentifier = "ai.goalong.localhistory.dev"
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
func devInstances() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: devIdentifier).filter { !$0.isTerminated }
}
func wait(seconds: TimeInterval, until predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !predicate(), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return predicate()
}
let usage = """
Usage: dev-app-control quit-dev | status | running-at APP | wait-running APP
       | badge-icon IN OUT | seed-data clone|keep|fresh REAL DEV | copy-blocking REAL DEV
"""
let arguments = Array(CommandLine.arguments.dropFirst())
guard let action = arguments.first else { fail(usage) }

/// The DEV bundle icon: the release icon with an orange "DEV" band (Dock, Cmd-Tab, Finder, notifications).
func badgeIcon(_ input: String, _ output: String) -> Never {
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

/// Refuses anything but `…/LocalHistory` -> sibling `…/LocalHistory-Dev`, both plain folders (no links).
func checkedDataPaths(_ realPath: String, _ devPath: String) -> (real: URL, dev: URL) {
    let real = URL(fileURLWithPath: realPath).standardizedFileURL, dev = URL(fileURLWithPath: devPath).standardizedFileURL
    guard real.lastPathComponent == "LocalHistory", dev.lastPathComponent == "LocalHistory-Dev",
          real.deletingLastPathComponent() == dev.deletingLastPathComponent() else { fail("Refusing data paths: \(realPath) -> \(devPath)") }
    var info = stat()
    if lstat(dev.path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR { fail("Dev data folder is not a plain folder: \(dev.path)") }
    return (real, dev)
}

/// Never cloned into Goalong Dev: the real stakes (Blocking, Focus and their backups), sockets,
/// backups, and every device or account identity (the dev copy creates its own device key).
let skippedTopLevel: Set<String> = [
    "Blocking", "Focus", "app-backups", "setup-backups", "runtime",
    "device-signing-key-v2.bin", "website-connections",
]
let skippedPrefixes = ["blocking-backup-"]
/// Account credentials inside cloned folders, removed from the clone right after.
let skippedNested = ["jev/api-key", "chatgpt/codex-home", "chatgpt/site-analysis-codex-home"]

/// clone: re-seeds LocalHistory-Dev from LocalHistory with APFS clones (instant, no extra disk).
/// keep: keeps the dev state (clones once if it does not exist). fresh: empty, like a new user.
/// Never writes inside LocalHistory.
func seedData(_ mode: String, _ realPath: String, _ devPath: String) -> Never {
    let fileManager = FileManager.default
    let (real, dev) = checkedDataPaths(realPath, devPath)
    var info = stat()
    let devExists = lstat(dev.path, &info) == 0
    if mode == "keep", devExists { print("Dev data kept: \(dev.path)"); exit(0) }
    guard ["clone", "keep", "fresh"].contains(mode) else { fail(usage) }
    if devExists {
        do { try fileManager.removeItem(at: dev) } catch { fail("Cannot remove the previous dev data: \(error.localizedDescription)") }
    }
    guard mkdir(dev.path, 0o700) == 0 else { fail("Cannot create \(dev.path): \(String(cString: strerror(errno)))") }
    if mode == "fresh" { print("Dev data emptied (fresh): \(dev.path)"); exit(0) }
    guard lstat(real.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
        print("No real data to clone (\(real.path)): dev data starts empty."); exit(0)
    }
    let names: [String]
    do { names = try fileManager.contentsOfDirectory(atPath: real.path) } catch { fail("Cannot list \(real.path)") }
    for name in names.sorted() where !skippedTopLevel.contains(name) && !skippedPrefixes.contains(where: name.hasPrefix) {
        let source = real.appendingPathComponent(name).path, target = dev.appendingPathComponent(name).path
        guard clonefile(source, target, UInt32(CLONE_NOFOLLOW)) == 0 else {
            fail("APFS clone failed for \(name): \(String(cString: strerror(errno))). No full copy was attempted.")
        }
    }
    for relative in skippedNested {
        let target = dev.appendingPathComponent(relative)
        if lstat(target.path, &info) == 0 {
            do { try fileManager.removeItem(at: target) } catch { fail("Cannot drop \(relative) from the dev clone.") }
        }
    }
    print("Dev data cloned by APFS (no device key, account, Blocking or Focus): \(dev.path)")
    exit(0)
}

/// BLOCKING=copy: a snapshot of the real block lists only, without sessions, locks, password or freeze.
/// Reads LocalHistory/Blocking/blocking.json; writes LocalHistory-Dev/Blocking/blocking.json.
func copyBlocking(_ realPath: String, _ devPath: String) -> Never {
    let (real, dev) = checkedDataPaths(realPath, devPath)
    let source = real.appendingPathComponent("Blocking/blocking.json")
    let directory = dev.appendingPathComponent("Blocking", isDirectory: true)
    var info = stat()
    guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          let data = FileManager.default.contents(atPath: source.path),
          let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let version = document["version"] as? Int, var lists = document["lists"] as? [[String: Any]] else {
        print("No readable real block lists: Goalong Dev blocking stays empty."); exit(0)
    }
    for index in lists.indices {
        guard var program = lists[index]["program"] as? [String: Any] else { continue }
        program.removeValue(forKey: "lockedUntil")
        if let ranges = program["ranges"] as? [[String: Any]] {
            program["ranges"] = ranges.map { range in var free = range; free.removeValue(forKey: "lock"); return free }
        }
        lists[index]["program"] = program
    }
    let snapshot: [String: Any] = ["version": version, "lists": lists, "sessions": [Any]()]
    do {
        if lstat(directory.path, &info) == 0 { try FileManager.default.removeItem(at: directory) }
        guard mkdir(directory.path, 0o700) == 0 else { fail("Cannot create \(directory.path)") }
        let output = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        try output.write(to: directory.appendingPathComponent("blocking.json"), options: .atomic)
    } catch { fail("Cannot write the dev block lists: \(error.localizedDescription)") }
    print("Real block lists copied into Goalong Dev (no lock, password or active session): \(lists.count) list(s).")
    exit(0)
}

switch action {
case "badge-icon" where arguments.count == 3: badgeIcon(arguments[1], arguments[2])
case "seed-data" where arguments.count == 4: seedData(arguments[1], arguments[2], arguments[3])
case "copy-blocking" where arguments.count == 3: copyBlocking(arguments[1], arguments[2])
case "quit-dev" where arguments.count == 1:
    // Only Goalong Dev, wherever it runs from. A normal quit: never forced.
    let running = devInstances()
    for app in running {
        print("Quit requested: Goalong Dev PID \(app.processIdentifier), \(app.bundleURL?.path ?? "?")")
        guard app.terminate() else { fail("Goalong Dev refused to quit. Resolve its confirmation before retrying.") }
    }
    guard wait(seconds: 15, until: { running.allSatisfy(\.isTerminated) }) else {
        fail("Goalong Dev did not quit within 15 s; no forced termination was used.")
    }
    if running.isEmpty { print("Goalong Dev is not running.") }
case "running-at" where arguments.count == 2:
    // Exit 0 when a Goalong Dev runs from APP (make dev NO_LAUNCH refuses to replace it).
    let target = URL(fileURLWithPath: arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
    exit(devInstances().contains { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == target } ? 0 : 1)
case "wait-running" where arguments.count == 2:
    let target = URL(fileURLWithPath: arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
    guard wait(seconds: 20, until: {
        devInstances().contains { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == target && $0.isFinishedLaunching }
    }) else { fail("Goalong Dev did not finish launching from \(target.path).") }
    // Catch an immediate crash after Launch Services responds.
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    guard let app = devInstances().first(where: { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == target }) else {
        fail("Goalong Dev exited right after launch.")
    }
    print("Running: Goalong Dev PID \(app.processIdentifier), \(target.path)")
case "status" where arguments.count == 1:
    let running = devInstances()
    print(running.isEmpty ? "Goalong Dev: not running" : "Goalong Dev: running")
    for app in running { print("  PID \(app.processIdentifier): \(app.bundleURL?.path ?? "?")") }
default:
    fail(usage)
}
