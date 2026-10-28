// E2E driver for GitHub-hosted macOS runners only (T-045). Never run it on a personal Mac:
// it presses real controls in the target app.
// Usage: ax_driver trusted | dump BUNDLE FILE | press BUNDLE TEXT | status-item BUNDLE | windows BUNDLE
import AppKit
import ApplicationServices

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
}
func text(_ e: AXUIElement, _ name: String) -> String { (attr(e, name) as? String) ?? "" }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

func app(_ bundle: String) -> AXUIElement {
    for _ in 0..<40 {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            return AXUIElementCreateApplication(running.processIdentifier)
        }
        usleep(250_000)
    }
    FileHandle.standardError.write("app \(bundle) not running\n".data(using: .utf8)!); exit(3)
}

/// The app element plus its menu-bar extras (status item), which are not among its children.
func roots(_ bundle: String) -> [AXUIElement] {
    let a = app(bundle)
    var r = [a]
    if let extras = attr(a, "AXExtrasMenuBar") { r.append(extras as! AXUIElement) }
    return r
}

func walk(_ e: AXUIElement, depth: Int = 0, budget: inout Int, visit: (AXUIElement, Int) -> Bool) -> Bool {
    guard budget > 0, depth < 40 else { return false }
    budget -= 1
    if visit(e, depth) { return true }
    for c in children(e) where walk(c, depth: depth + 1, budget: &budget, visit: visit) { return true }
    return false
}

func describe(_ e: AXUIElement) -> String {
    let fields = [("role", kAXRoleAttribute), ("id", "AXIdentifier"), ("title", kAXTitleAttribute),
                  ("desc", kAXDescriptionAttribute), ("help", kAXHelpAttribute)]
    var parts = fields.compactMap { k, a -> String? in let v = text(e, a); return v.isEmpty ? nil : "\(k)=\(v)" }
    if let v = attr(e, kAXValueAttribute) as? String, !v.isEmpty { parts.append("value=\(v.prefix(80))") }
    return parts.joined(separator: " | ")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "trusted":
    print("AXIsProcessTrusted=\(AXIsProcessTrusted())")
case "dump":
    var out = ""
    for root in roots(args[2]) {
        var budget = 4000
        _ = walk(root, budget: &budget) { e, d in out += String(repeating: "  ", count: d) + describe(e) + "\n"; return false }
    }
    try! out.write(toFile: args[3], atomically: true, encoding: .utf8)
    print("dumped \(out.split(separator: "\n").count) nodes to \(args[3])")
case "press":
    // Exact AXIdentifier first, then a title/description containing the text.
    let needle = args[3]
    for exact in [true, false] {
        for root in roots(args[2]) {
            var budget = 6000
            var hit: AXUIElement?
            _ = walk(root, budget: &budget) { e, _ in
                let match = exact ? text(e, "AXIdentifier") == needle
                    : [kAXTitleAttribute, kAXDescriptionAttribute].contains { text(e, $0).contains(needle) }
                if match { hit = e }
                return match
            }
            if let hit {
                let status = AXUIElementPerformAction(hit, kAXPressAction as CFString)
                print("press '\(needle)' -> \(describe(hit)) : \(status.rawValue)")
                exit(status == .success ? 0 : 4)
            }
        }
    }
    print("press '\(needle)': not found"); exit(5)
case "status-item":
    guard let extras = attr(app(args[2]), "AXExtrasMenuBar") else { print("no AXExtrasMenuBar"); exit(6) }
    guard let item = children(extras as! AXUIElement).first else { print("no status item"); exit(6) }
    let status = AXUIElementPerformAction(item, kAXPressAction as CFString)
    print("status-item -> \(describe(item)) : \(status.rawValue)")
    exit(status == .success ? 0 : 4)
case "windows":
    let pid = NSRunningApplication.runningApplications(withBundleIdentifier: args[2]).first?.processIdentifier ?? -1
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
        print("id=\(w[kCGWindowNumber as String] ?? "") layer=\(w[kCGWindowLayer as String] ?? "") onscreen=\(w[kCGWindowIsOnscreen as String] ?? 0) name=\(w[kCGWindowName as String] ?? "-") bounds=\(w[kCGWindowBounds as String] ?? "")")
    }
default:
    print("usage: ax_driver trusted | dump B F | press B TEXT | status-item B | windows B"); exit(2)
}
