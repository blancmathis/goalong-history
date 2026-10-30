// E2E driver for GitHub-hosted macOS runners only (T-045). Never run it on a personal Mac:
// it presses real controls in the target app.
// Usage: ax_driver trusted | dump BUNDLE FILE | press BUNDLE TEXT [ROLE] | menu BUNDLE TOP [ITEM]
//        | close-extra BUNDLE MAIN_TITLE | status-item BUNDLE | status-menu BUNDLE | windows BUNDLE | input SECONDS
//        | dismiss-alerts BUNDLE | scroll BUNDLE | set BUNDLE ID 0|1 | settext BUNDLE ID|LABEL TEXT
//        | act BUNDLE ACTION MODE ROLE NEEDLE SCROLLS (T-046, one matrix row) | textshot IN.txt OUT.png
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
            let e = AXUIElementCreateApplication(running.processIdentifier)
            AXUIElementSetMessagingTimeout(e, 4)  // A modal can make the app stop answering: fail fast.
            return e
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
case "pressprefix":
    // First element whose AXIdentifier starts with PREFIX (ids with a variable tail: blocking-suggestion-<id>).
    let prefix = args[3]
    for root in roots(args[2]) {
        var budget = 6000
        var hit: AXUIElement?
        _ = walk(root, budget: &budget) { e, _ in
            let match = text(e, "AXIdentifier").hasPrefix(prefix)
            if match { hit = e }
            return match
        }
        if let hit {
            let status = AXUIElementPerformAction(hit, kAXPressAction as CFString)
            print("pressprefix '\(prefix)' -> \(describe(hit)) : \(status.rawValue)")
            exit(status == .success || status.rawValue == -25204 ? 0 : 4)
        }
    }
    print("pressprefix '\(prefix)': not found"); exit(5)
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
case "scroll":
    // One scroll step down in the main window, for content below the fold (lazy stacks only expose realized rows).
    // Scroll bars first (AX), then synthetic wheel events over the window (runner only: the cursor is moved there).
    let a = app(args[2])
    var budget = 6000
    _ = walk(a, budget: &budget) { e, _ in
        if text(e, kAXRoleAttribute) == "AXScrollArea", let bar = attr(e, "AXVerticalScrollBar"),
           let v = attr(bar as! AXUIElement, kAXValueAttribute) as? Double {
            AXUIElementSetAttributeValue(bar as! AXUIElement, kAXValueAttribute as CFString, min(1.0, v + 0.25) as CFNumber)
        }
        return false
    }
    if let w = (attr(a, kAXWindowsAttribute) as? [AXUIElement])?.first,
       let pos = attr(w, kAXPositionAttribute), let size = attr(w, kAXSizeAttribute) {
        var p = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p); AXValueGetValue(size as! AXValue, .cgSize, &sz)
        CGWarpMouseCursorPosition(CGPoint(x: p.x + sz.width * 0.6, y: p.y + sz.height * 0.6))
        for _ in 0..<3 {
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -150, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
            usleep(100_000)
        }
    }
    print("scrolled")
case "set":
    // Put a checkbox/switch (by AXIdentifier) in the wanted state: press only when its AXValue differs.
    var budget = 6000
    var hit: AXUIElement?
    for root in roots(args[2]) {
        _ = walk(root, budget: &budget) { e, _ in
            let ok = text(e, "AXIdentifier") == args[3]
            if ok { hit = e }
            return ok
        }
    }
    guard let hit else { print("set '\(args[3])': not found"); exit(5) }
    let now = (attr(hit, kAXValueAttribute) as? NSNumber)?.intValue ?? -1
    var status = AXError.success
    if now != Int(args[4]) { status = AXUIElementPerformAction(hit, kAXPressAction as CFString); usleep(500_000) }
    let after = (attr(hit, kAXValueAttribute) as? NSNumber)?.intValue ?? -1
    print("set '\(args[3])' \(now) -> \(after) (wanted \(args[4])) : \(status.rawValue)")
    exit(after == Int(args[4]) ? 0 : 4)
case "settext":
    // Type TEXT into a text field found by exact AXIdentifier, else by a title/description/placeholder containing ID|LABEL.
    // L3d: a search with no result, a domain to exclude, the saved work definition (state seeded through the UI).
    var hit: AXUIElement?
    for exact in [true, false] where hit == nil {
        for root in roots(args[2]) where hit == nil {
            var budget = 6000
            _ = walk(root, budget: &budget) { e, _ in
                let r = text(e, kAXRoleAttribute)
                guard ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(r) else { return false }
                let ok = exact ? text(e, "AXIdentifier") == args[3]
                    : [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute].contains { text(e, $0).contains(args[3]) }
                if ok { hit = e }
                return ok
            }
        }
    }
    guard let hit else { print("settext '\(args[3])': not found"); exit(5) }
    AXUIElementSetAttributeValue(hit, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let s = AXUIElementSetAttributeValue(hit, kAXValueAttribute as CFString, args[4] as CFString)
    usleep(500_000)
    let now = (attr(hit, kAXValueAttribute) as? String) ?? ""
    print("settext '\(args[3])' -> \(describe(hit)) : \(s.rawValue)")
    exit(now == args[4] ? 0 : 4)
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
case "act":
    // T-046: one matrix row. MODE id | idprefix | label | dialog | menuitem | role; ROLE may be empty.
    // ACTION click | toggle | type | observe | menu | shortcut. Not found: scroll and retry SCROLLS times.
    // Prints key=value lines; exit 0 = found and the action's check held, 1 = found but the check failed, 5 = not found.
    let (bundle, action, mode, role, needle) = (args[2], args[3], args[4], args[5], args[6])
    let scrolls = Int(args.count > 7 ? args[7] : "3") ?? 3
    let a = app(bundle)
    func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{a0}", with: " ").replacingOccurrences(of: "\u{202f}", with: " ")
            .replacingOccurrences(of: "'", with: "’")
    }
    let n = norm(needle)
    func texts(_ e: AXUIElement) -> [String] {
        var t = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].map { norm(text(e, $0)) }
        if let v = attr(e, kAXValueAttribute) as? String { t.append(norm(v)) }
        return t
    }
    func isDialog(_ e: AXUIElement) -> Bool {
        ["AXDialog", "AXSystemDialog"].contains(text(e, kAXSubroleAttribute)) || text(e, kAXRoleAttribute) == "AXSheet"
            || text(e, kAXDescriptionAttribute) == "alerte"
    }
    func subtreeHas(_ e: AXUIElement, _ s: String) -> Bool {
        var budget = 800
        return walk(e, budget: &budget) { x, _ in texts(x).contains { $0.contains(s) } }
    }
    func searchRoots() -> [AXUIElement] {
        var r = (attr(a, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        r.append(a)
        if let x = attr(a, "AXExtrasMenuBar") { r.append(x as! AXUIElement) }
        if mode == "menuitem" || role == "AXMenuItem", let b = attr(a, kAXMenuBarAttribute) { r.append(b as! AXUIElement) }
        return r
    }
    func find(roleStrict: Bool) -> AXUIElement? {
        var hit: AXUIElement?
        for root in searchRoots() {
            var budget = 8000
            _ = walk(root, budget: &budget) { e, _ in
                let r = text(e, kAXRoleAttribute)
                // Dialog mode: isDialog decides (an alert shows as AXSheet desc=alerte, not only AXDialog; L3c).
                let roleOK = mode == "dialog" ? true
                    : role.isEmpty || !roleStrict ? (mode == "menuitem" || role == "AXMenuItem" || !["AXMenuItem", "AXMenuBarItem"].contains(r)) : r == role
                guard roleOK else { return false }
                let ok: Bool
                switch mode {
                case "id": ok = text(e, "AXIdentifier") == needle
                case "idprefix": ok = text(e, "AXIdentifier").hasPrefix(needle)
                case "dialog": ok = isDialog(e) && (n.isEmpty || subtreeHas(e, n))
                case "role": ok = r == role
                default: ok = texts(e).contains { $0.contains(n) }
                }
                if ok { hit = e }
                return ok
            }
            if hit != nil { return hit }
        }
        return nil
    }
    func signature() -> Int {
        var h = Hasher(), budget = 3000
        for w in (attr(a, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            _ = walk(w, budget: &budget) { e, _ in h.combine(describe(e)); return false }
        }
        return h.finalize()
    }
    func scrollOnce() {
        var budget = 6000
        _ = walk(a, budget: &budget) { e, _ in
            if text(e, kAXRoleAttribute) == "AXScrollArea", let bar = attr(e, "AXVerticalScrollBar"),
               let v = attr(bar as! AXUIElement, kAXValueAttribute) as? Double {
                AXUIElementSetAttributeValue(bar as! AXUIElement, kAXValueAttribute as CFString, min(1.0, v + 0.3) as CFNumber)
            }
            return false
        }
        usleep(700_000)
    }
    var el: AXUIElement?
    for attempt in 0...scrolls {
        // A sheet, dialog, window or popover row needs that container: no fallback to its opener's label.
        el = find(roleStrict: true) ?? (["AXSheet", "AXDialog", "AXWindow", "AXPopover"].contains(role) ? nil : find(roleStrict: false))
        if el != nil || mode == "dialog" { break }
        if attempt < scrolls { scrollOnce() }
    }
    guard let e = el else { print("found=0"); exit(5) }
    print("found=1"); print("element=\(describe(e))")
    let r = text(e, kAXRoleAttribute)
    func value() -> String { attr(e, kAXValueAttribute).map { "\($0)" } ?? "nil" }
    func press() -> Int32 { AXUIElementPerformAction(e, kAXPressAction as CFString).rawValue }
    func okStatus(_ s: Int32) -> Bool { s == 0 || s == -25204 }
    var pass = true
    switch action {
    case "click" where r == "AXSlider":
        let s = AXUIElementPerformAction(e, kAXIncrementAction as CFString).rawValue; usleep(400_000)
        _ = AXUIElementPerformAction(e, kAXDecrementAction as CFString)
        print("increment=\(s)")
        pass = okStatus(s)
    case "click":
        let before = signature(); let s = press(); usleep(1_200_000)
        print("press=\(s)"); print("changed=\(before != signature() ? 1 : 0)")
        pass = okStatus(s)
    case "toggle":
        let before = signature(); let v0 = value(); let s = press(); usleep(900_000); let v1 = value()
        let opened = before != signature()
        print("press=\(s)"); print("value=\(v0)->\(v1)"); print("changed=\(opened ? 1 : 0)")
        if v1 != v0 { _ = press(); usleep(500_000); print("restored=\(value())") }
        // A gated switch answers with a sheet or a message instead of flipping: that answer counts.
        pass = v1 != v0 || (okStatus(s) && opened)
    case "type":
        let v0 = value()
        AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(r) || text(e, kAXSubroleAttribute) == "AXSearchField" {
            let probe = "T046 synthétique"
            let s = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, probe as CFString).rawValue
            usleep(500_000); let v1 = value()
            print("set=\(s)"); print("value=\(v0.prefix(60))->\(v1.prefix(60))")
            AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, (v0 == "nil" ? "" : v0) as CFString)
            pass = v1.contains(probe)
        } else {
            // Date/time pickers: the value is read and written back as is (accepted or refused, status kept).
            let cur = attr(e, kAXValueAttribute)
            let s = cur.map { AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, $0).rawValue } ?? -1
            print("value=\(v0)"); print("set=\(s)")
            pass = cur != nil
        }
    case "menu":
        if r == "AXMenuItem" {
            let enabled = (attr(e, kAXEnabledAttribute) as? Bool) ?? false
            let s = press(); usleep(800_000)
            print("enabled=\(enabled)"); print("press=\(s)"); pass = enabled && okStatus(s)
        } else {
            var s = AXUIElementPerformAction(e, kAXShowMenuAction as CFString).rawValue
            if !okStatus(s) { s = press() }
            usleep(800_000)
            var items = 0, budget = 4000
            _ = walk(a, budget: &budget) { x, _ in if text(x, kAXRoleAttribute) == "AXMenuItem" && text(x, kAXTitleAttribute) != "" { items += 1 }; return false }
            print("press=\(s)"); print("menu_items_visible=\(items)")
            pass = okStatus(s)
        }
    case "shortcut", "escape":
        // .defaultAction button: Return; .cancelAction button (action escape): Escape. Sent to the app.
        let before = signature()
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first!.processIdentifier
        NSRunningApplication(processIdentifier: pid)?.activate()
        AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(300_000)
        let src = CGEventSource(stateID: .hidSystemState)
        let key: CGKeyCode = action == "escape" ? 0x35 : 0x24
        for down in [true, false] { CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)?.post(tap: .cghidEventTap) }
        usleep(1_200_000)
        let changed = before != signature()
        print("key=\(action == "escape" ? "Escape" : "Return")"); print("changed=\(changed ? 1 : 0)"); pass = changed
    default:  // observe
        print("role=\(r)"); print("enabled=\((attr(e, kAXEnabledAttribute) as? Bool).map { "\($0)" } ?? "-")")
    }
    exit(pass ? 0 : 1)
case "textshot":
    // A transcript as a PNG, drawn off screen (no window).
    let body = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? "(unreadable)"
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false).prefix(120).map { String($0.prefix(160)) }
    let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let size = NSSize(width: 1100, height: max(80, 16 * lines.count + 24))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
    for (i, l) in lines.enumerated() {
        (l as NSString).draw(at: NSPoint(x: 12, y: size.height - 20 - CGFloat(16 * i)), withAttributes: [.font: font, .foregroundColor: NSColor.black])
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
default:
    print("usage: ax_driver trusted | dump B F | press B TEXT [ROLE] | pressprefix B PREFIX | menu B TOP ITEM | status-item B | status-menu B | windows B | input S"); exit(2)
}
