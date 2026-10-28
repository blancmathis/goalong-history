// E2E driver for GitHub-hosted macOS runners only (T-045). Never run it on a personal Mac:
// it presses real controls in the target app.
// Usage: ax_driver trusted | dump BUNDLE FILE | press BUNDLE TEXT [ROLE] | menu BUNDLE TOP [ITEM]
//        | close-extra BUNDLE MAIN_TITLE | status-item BUNDLE | status-menu BUNDLE | windows BUNDLE | input SECONDS
//        | dismiss-alerts BUNDLE
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
    // An optional ROLE (e.g. AXButton) keeps a label from matching a menu item of the same name.
    let needle = args[3]
    let role = args.count > 4 ? args[4] : ""
    for exact in [true, false] {
        for root in roots(args[2]) {
            var budget = 6000
            var hit: AXUIElement?
            _ = walk(root, budget: &budget) { e, _ in
                // Without ROLE, menu items never match: « Rechercher » must not press « Rechercher les mises à jour… ».
                let r = text(e, kAXRoleAttribute)
                let roleOK = role.isEmpty ? !["AXMenuItem", "AXMenuBarItem"].contains(r) : r == role
                let match = roleOK && (exact ? text(e, "AXIdentifier") == needle
                    : [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].contains { text(e, $0).contains(needle) })
                if match { hit = e }
                return match
            }
            if let hit {
                let status = AXUIElementPerformAction(hit, kAXPressAction as CFString)
                print("press '\(needle)' -> \(describe(hit)) : \(status.rawValue)")
                // -25204 (cannot complete): the press opened a modal menu or popover and the app stopped answering
                // until it closes; the action ran. The capture after the press is the proof.
                exit(status == .success || status.rawValue == -25204 ? 0 : 4)
            }
        }
    }
    print("press '\(needle)': not found"); exit(5)
case "menu":
    // Application menu: TOP is the menu-bar title, ITEM a prefix of the item title (submenus searched too).
    guard let bar = attr(app(args[2]), kAXMenuBarAttribute) else { print("no menu bar"); exit(6) }
    guard let top = children(bar as! AXUIElement).first(where: { text($0, kAXTitleAttribute) == args[3] }) else {
        print("menu '\(args[3])' not found"); exit(5)
    }
    if args.count < 5 {  // No ITEM: open the menu itself.
        let status = AXUIElementPerformAction(top, kAXPressAction as CFString)
        print("menu '\(args[3])' opened : \(status.rawValue)"); exit(status == .success ? 0 : 4)
    }
    var budget = 2000
    var hit: AXUIElement?
    _ = walk(top, budget: &budget) { e, _ in
        let ok = text(e, kAXRoleAttribute) == "AXMenuItem" && text(e, kAXTitleAttribute).hasPrefix(args[4])
        if ok { hit = e }
        return ok
    }
    guard let hit else { print("menu item '\(args[4])' not found"); exit(5) }
    let status = AXUIElementPerformAction(hit, kAXPressAction as CFString)
    print("menu '\(args[3])' > \(describe(hit)) : \(status.rawValue)")
    exit(status == .success ? 0 : 4)
case "close-extra":
    // Close every window of the app except the main one (support report, about, update windows).
    let main = args[3]
    var closed = 0
    for w in (attr(app(args[2]), kAXWindowsAttribute) as? [AXUIElement]) ?? [] where text(w, kAXTitleAttribute) != main {
        if let b = attr(w, kAXCloseButtonAttribute) { AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString); closed += 1 }
    }
    print("closed \(closed) extra window(s)")
case "status-menu":
    guard let extras = attr(app(args[2]), "AXExtrasMenuBar") else { print("no AXExtrasMenuBar"); exit(6) }
    guard let item = children(extras as! AXUIElement).first else { print("no status item"); exit(6) }
    let status = AXUIElementPerformAction(item, kAXShowMenuAction as CFString)
    print("status-menu -> \(describe(item)) : \(status.rawValue)")
    exit(status == .success ? 0 : 4)
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
case "dismiss-alerts":
    // Close leftover alerts (e.g. « Configuration rechargée » after MNB-07): an app-modal alert blocks every later step.
    var closed = 0
    for w in (attr(app(args[2]), kAXWindowsAttribute) as? [AXUIElement]) ?? []
    where ["AXDialog", "AXSystemDialog"].contains(text(w, kAXSubroleAttribute)) || text(w, kAXDescriptionAttribute) == "alerte" {
        if let b = attr(w, kAXCancelButtonAttribute) ?? attr(w, kAXDefaultButtonAttribute) {
            AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString); closed += 1
        }
    }
    print("dismissed \(closed) alert(s)")
case "input":
    // Synthetic HID input into the frontmost app (runner only): mouse moves and letter keys, so the
    // app's listen-only event tap counts active time. Typed text goes into the runner's synthetic note.
    let seconds = Double(args.count > 2 ? args[2] : "60") ?? 60
    let source = CGEventSource(stateID: .hidSystemState)
    let keys: [CGKeyCode] = [0x0E, 0x11, 0x01, 0x11, 0x31]  // e t s t space
    let end = Date().addingTimeInterval(seconds)
    var i = 0, posted = 0
    while Date() < end {
        let p = CGPoint(x: 400 + Double(i % 40) * 5, y: 300 + Double(i % 25) * 4)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        if i % 3 == 0 {
            let k = keys[(i / 3) % keys.count]
            CGEvent(keyboardEventSource: source, virtualKey: k, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: k, keyDown: false)?.post(tap: .cghidEventTap)
        }
        posted += 1; i += 1
        usleep(200_000)
    }
    print("input: \(posted) synthetic events in \(Int(seconds)) s")
default:
    print("usage: ax_driver trusted | dump B F | press B TEXT [ROLE] | menu B TOP ITEM | status-item B | status-menu B | windows B | input S"); exit(2)
}
