// Test window guard: fails when a test process shows a window to the person working on this Mac.
//   window_guard watch ROOT_PID   polls every 50 ms until ROOT_PID exits or SIGUSR1 arrives; watches
//                                 ROOT_PID and its descendants (swift test, xctest, swiftpm-testing-helper).
//   window_guard check PID...     one look at these processes.
// A window counts when the window server has it on screen, with alpha > 0, at least 2x2 points and
// inside a display. Focus counts too: a watched process frontmost. On a violation the offending
// process gets SIGTERM at once (its window disappears with it), one line `[window-guard] VIOLATION`
// is printed, and the exit status is 1. Needs no permission: owner PID, bounds, alpha and layer are
// public in CGWindowList (window names are not, without Screen Recording).
import AppKit
import CoreGraphics

setvbuf(stdout, nil, _IOLBF, 0)

func children() -> [pid_t: [pid_t]] {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-axo", "pid=,ppid="]
    let pipe = Pipe()
    ps.standardOutput = pipe
    guard (try? ps.run()) != nil else { return [:] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()
    var map: [pid_t: [pid_t]] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]) else { continue }
        map[ppid, default: []].append(pid)
    }
    return map
}

// ROOT_PID and its descendants only: another checkout's tests running at the same time are not ours.
func watched(root: pid_t) -> Set<pid_t> {
    let map = children()
    var seen = Set<pid_t>()
    var queue = [root]
    while let pid = queue.popLast() {
        guard seen.insert(pid).inserted else { continue }
        queue.append(contentsOf: map[pid] ?? [])
    }
    seen.remove(getpid())
    return seen
}

func displays() -> [CGRect] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.map { CGDisplayBounds($0) }
}

var violations = 0
// Self-test only: report without killing (used on a process that is not a test, e.g. the Dock).
let noKill = ProcessInfo.processInfo.environment["WINDOW_GUARD_NO_KILL"] == "1"
var reported = Set<String>()

func look(at pids: Set<pid_t>) {
    let screens = displays()
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in list {
        guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid) else { continue }
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        guard alpha > 0.001,
              let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsInfo),
              bounds.width >= 2, bounds.height >= 2,
              screens.contains(where: { $0.intersects(bounds) }) else { continue }
        let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
        let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let key = "\(pid)-\(number)"
        if reported.insert(key).inserted {
            print("[window-guard] VIOLATION visible window: pid \(pid) \(owner) window \(number) layer \(layer) alpha \(alpha) bounds \(bounds)")
        }
        violations += 1
        if !noKill { kill(pid, SIGTERM) }
    }
    if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, pids.contains(front) {
        if reported.insert("front-\(front)").inserted {
            print("[window-guard] VIOLATION focus: pid \(front) became the frontmost app")
        }
        violations += 1
        if !noKill { kill(front, SIGTERM) }
    }
}

nonisolated(unsafe) var stopRequested: sig_atomic_t = 0
let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "watch":
    signal(SIGUSR1) { _ in stopRequested = 1 }
    guard let root = arguments.dropFirst().first.flatMap({ pid_t($0) }) else { print("usage: window_guard watch ROOT_PID"); exit(2) }
    var cached = watched(root: root)
    var tick = 0
    while kill(root, 0) == 0 && stopRequested == 0 {
        if tick % 10 == 0 { cached = watched(root: root) }   // the process tree every 0.5 s, windows every 50 ms
        look(at: cached)
        tick += 1
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))   // also keeps frontmostApplication fresh
    }
case "check":
    let pids = Set(arguments.dropFirst().compactMap { pid_t($0) })
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    look(at: pids)
default:
    print("usage: window_guard watch ROOT_PID | check PID...")
    exit(2)
}
print(violations == 0 ? "[window-guard] ok: no test window on screen, no focus taken" : "[window-guard] FAILED: \(violations) visible window or focus event(s)")
exit(violations == 0 ? 0 : 1)
