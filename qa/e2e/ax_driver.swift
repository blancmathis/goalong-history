// E2E driver for GitHub-hosted macOS runners only (T-045). Never run it on a personal Mac:
// it presses real controls in the target app.
// Usage: ax_driver trusted | dump BUNDLE FILE | press BUNDLE TEXT [ROLE] | menu BUNDLE TOP [ITEM]
//        | close-extra BUNDLE MAIN_TITLE | status-item BUNDLE | status-menu BUNDLE | windows BUNDLE | input SECONDS
//        | dismiss-alerts BUNDLE | scroll BUNDLE | set BUNDLE ID 0|1 | settext BUNDLE ID|LABEL TEXT
//        | pressexact BUNDLE TEXT [ROLE] | popup BUNDLE OPENER [ITEM] [DUMP] [click] | typekeys BUNDLE ID|LABEL TEXT (L3e)
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
    // L3h: a checkbox's state is a number (Braise day boxes, J-0751): in the dump and in act's signature.
    if toggleRoles.contains(text(e, kAXRoleAttribute)), let v = attr(e, kAXValueAttribute) as? NSNumber { parts.append("value=\(v.intValue)") }
    return parts.joined(separator: " | ")
}
let toggleRoles = ["AXCheckBox", "AXSwitch", "AXToggle", "AXRadioButton", "AXDisclosureTriangle"]

func centerOf(_ e: AXUIElement) -> CGPoint? {
    guard let pos = attr(e, kAXPositionAttribute), let size = attr(e, kAXSizeAttribute) else { return nil }
    var p = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(pos as! AXValue, .cgPoint, &p); AXValueGetValue(size as! AXValue, .cgSize, &sz)
    return CGPoint(x: p.x + sz.width / 2, y: p.y + sz.height / 2)
}
func mouseClick(_ c: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(200_000)
    for t in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(80_000)
    }
}
func postKey(_ code: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] { CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap) }
}
func typeText(_ s: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    for ch in s.utf16 {
        var u = ch
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
            ev?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            ev?.post(tap: .cghidEventTap)
        }
        usleep(25_000)
    }
}
/// L3h: an open menu's item whose title contains ITEM (empty: any titled item), outside the app's main menu bar
/// (the status item's extras bar is searched, as before).
func menuItem(_ bundle: String, _ item: String, extra: [AXUIElement] = []) -> AXUIElement? {
    var hit: AXUIElement?
    let bar = attr(app(bundle), kAXMenuBarAttribute)
    func rec(_ e: AXUIElement, _ d: Int, _ budget: inout Int) {
        guard hit == nil, budget > 0, d < 40 else { return }
        budget -= 1
        if let bar, CFEqual(e, bar) { return }
        let r = text(e, kAXRoleAttribute)
        if r == "AXMenuItem" {
            let t = normText(text(e, kAXTitleAttribute))
            if item.isEmpty ? !t.isEmpty : t.contains(item) { hit = e; return }
        }
        for c in children(e) { rec(c, d + 1, &budget) }
    }
    for root in extra + roots(bundle) where hit == nil { var budget = 8000; rec(root, 0, &budget) }
    return hit
}
/// L3h: open TARGET's menu. AXPress first (AXShowMenu if refused); a SwiftUI Menu (AXMenuButton) pressed so shows no
/// item in the AX tree (J-0427, J-0475): Escape, then a mouse click on the button. Returns true when items show.
func openMenu(_ bundle: String, _ target: AXUIElement) -> Bool {
    AXUIElementSetMessagingTimeout(target, 1.5)
    var s = AXUIElementPerformAction(target, kAXPressAction as CFString).rawValue
    if s != 0 && s != -25204 { s = AXUIElementPerformAction(target, kAXShowMenuAction as CFString).rawValue }
    print("menu opener -> \(describe(target)) : \(s)")
    usleep(700_000)
    for _ in 0..<5 {  // As before L3h: the items may take up to 3 s to show.
        if menuItem(bundle, "", extra: [target]) != nil { return true }
        usleep(500_000)
    }
    guard let c = centerOf(target) else { return false }
    postKey(0x35); usleep(400_000)
    mouseClick(c); usleep(800_000)
    let shown = menuItem(bundle, "", extra: [target]) != nil
    print("menu mouse click at \(Int(c.x)),\(Int(c.y)) items=\(shown ? 1 : 0)")
    return shown
}
/// L3h: open TARGET's menu and choose ITEM (AXPress, or a mouse click with CLICK). Items not in the AX tree under an
/// open AXMenuButton: type the item's first word (menu type-select) and Return. False: nothing chosen, menu closed.
func pickItem(_ bundle: String, _ target: AXUIElement, _ item: String, click: Bool = false) -> Bool {
    let shown = openMenu(bundle, target)
    var hit: AXUIElement?
    for _ in 0..<(shown ? 6 : 1) where hit == nil {
        hit = menuItem(bundle, item, extra: [target])
        if hit == nil { usleep(500_000) }
    }
    if let hit {
        AXUIElementSetMessagingTimeout(hit, 1.5)
        if click, let c = centerOf(hit) { mouseClick(c); print("picked=click \(describe(hit))"); return true }
        let s = AXUIElementPerformAction(hit, kAXPressAction as CFString).rawValue
        print("picked=press \(describe(hit)) : \(s)")
        return s == 0 || s == -25204
    }
    if !shown && text(target, kAXRoleAttribute) == "AXMenuButton" {
        typeText(String(item.split(separator: " ").first ?? "")); usleep(300_000); postKey(0x24)
        print("picked=typed \(item)")
        return true
    }
    postKey(0x35)  // An open menu blocks the next rows.
    print("picked=0 '\(item)' not found")
    return false
}

func dumpTree(_ bundle: String, to path: String) -> Int {
    var out = ""
    for root in roots(bundle) {
        var budget = 4000
        _ = walk(root, budget: &budget) { e, d in out += String(repeating: "  ", count: d) + describe(e) + "\n"; return false }
    }
    try? out.write(toFile: path, atomically: true, encoding: .utf8)
    return out.split(separator: "\n").count
}
func normText(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{a0}", with: " ").replacingOccurrences(of: "\u{202f}", with: " ")
        .replacingOccurrences(of: "'", with: "’")
}
let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
/// L3e: a text field by exact AXIdentifier, then a title/description/placeholder equal to NEEDLE, then containing it.
func findField(_ bundle: String, _ needle: String) -> AXUIElement? {
    let n = normText(needle)
    let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute]
    for pass in 0..<3 {
        for root in roots(bundle) {
            var budget = 6000
            var hit: AXUIElement?
            _ = walk(root, budget: &budget) { e, _ in
                guard textRoles.contains(text(e, kAXRoleAttribute)) else { return false }
                let ok = pass == 0 ? text(e, "AXIdentifier") == needle
                    : labels.contains { pass == 1 ? normText(text(e, $0)) == n : normText(text(e, $0)).contains(n) }
                if ok { hit = e }
                return ok
            }
            if let hit { return hit }
        }
    }
    return nil
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "trusted":
    print("AXIsProcessTrusted=\(AXIsProcessTrusted())")
case "dump":
    print("dumped \(dumpTree(args[2], to: args[3])) nodes to \(args[3])")
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
case "pressexact":
    // L3e: title or description equal to TEXT (a tab « Données » next to a button « Données pour ChatGPT… »).
    let n = normText(args[3]), role = args.count > 4 ? args[4] : ""
    for root in roots(args[2]) {
        var budget = 6000
        var hit: AXUIElement?
        _ = walk(root, budget: &budget) { e, _ in
            let r = text(e, kAXRoleAttribute)
            let roleOK = role.isEmpty ? !["AXMenuItem", "AXMenuBarItem", "AXStaticText"].contains(r) : r == role
            let ok = roleOK && [kAXTitleAttribute, kAXDescriptionAttribute].contains { normText(text(e, $0)) == n }
            if ok { hit = e }
            return ok
        }
        if let hit {
            let status = AXUIElementPerformAction(hit, kAXPressAction as CFString)
            print("pressexact '\(args[3])' -> \(describe(hit)) : \(status.rawValue)")
            exit(status == .success || status.rawValue == -25204 ? 0 : 4)
        }
    }
    print("pressexact '\(args[3])': not found"); exit(5)
case "popup":
    // L3e: open a menu (SwiftUI Menu, pop-up button, the status item's « Plus d’options ») and pick ITEM in the same
    // process. The opener's press can block while the menu tracks: short timeout, then the items are read at once.
    // No ITEM: open only, the row's act picks the item. DUMP: the AX tree right after the opener press (proof).
    let bundle = args[2], opener = normText(args[3])
    let item = normText(args.count > 4 ? args[4] : ""), dumpPath = args.count > 5 ? args[5] : ""
    var target: AXUIElement?
    for exact in [true, false] where target == nil {
        for root in roots(bundle) where target == nil {
            var budget = 6000
            _ = walk(root, budget: &budget) { e, _ in
                guard !["AXMenuItem", "AXMenuBarItem", "AXStaticText"].contains(text(e, kAXRoleAttribute)) else { return false }
                let ok = exact ? text(e, "AXIdentifier") == args[3]
                    : [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].contains { normText(text(e, $0)).contains(opener) }
                if ok { target = e }
                return ok
            }
        }
    }
    guard let target else { print("popup '\(args[3])': opener not found"); exit(5) }
    // L3h: openMenu / pickItem (SwiftUI Menu fallback: Escape, mouse click, type-select).
    // L3f: CLICK (6th argument) clicks the item with the mouse: AXPress on a pop-up item ran but chose nothing (J-0643).
    if item.isEmpty {
        let shown = openMenu(bundle, target)
        if !dumpPath.isEmpty { print("dumped \(dumpTree(bundle, to: dumpPath)) nodes to \(dumpPath)") }
        exit(shown ? 0 : 4)
    }
    exit(pickItem(bundle, target, item, click: args.count > 6 && args[6] == "click") ? 0 : 5)
case "typekeys":
    // L3e: settext does not reach a SwiftUI binding (L3d). Focus the field, click it, then type TEXT as key events.
    guard let hit = findField(args[2], args[3]) else { print("typekeys '\(args[3])': not found"); exit(5) }
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: args[2]).first { running.activate() }
    AXUIElementSetAttributeValue(hit, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    if let pos = attr(hit, kAXPositionAttribute), let size = attr(hit, kAXSizeAttribute) {
        var p = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p); AXValueGetValue(size as! AXValue, .cgSize, &sz)
        let c = CGPoint(x: p.x + min(sz.width / 2, 40), y: p.y + sz.height / 2)
        for t in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }
    usleep(400_000)
    let src = CGEventSource(stateID: .hidSystemState)
    for ch in args[4].utf16 {
        var u = ch
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
            ev?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            ev?.post(tap: .cghidEventTap)
        }
        usleep(25_000)
    }
    usleep(500_000)
    let now = (attr(hit, kAXValueAttribute) as? String) ?? ""
    print("typekeys '\(args[3])' -> \(describe(hit)) value=\(now.prefix(80))")
    exit(now.isEmpty || now.contains(args[4]) ? 0 : 4)  // A custom text area may expose no value: typed is enough.
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
    exit(status == .success || status.rawValue == -25204 ? 0 : 4)  // L3e: an alert opened by the item blocks the reply.
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
    // L3f: else a checkbox/switch whose title or description equals ID (unlabeled ids: « Activité de ce Mac »).
    var hit: AXUIElement?
    for byLabel in [false, true] where hit == nil {
        for root in roots(args[2]) where hit == nil {
            var budget = 6000
            _ = walk(root, budget: &budget) { e, _ in
                let ok = byLabel ? toggleRoles.contains(text(e, kAXRoleAttribute))  // L3h: and disclosure triangles (J-0424)
                    && [kAXTitleAttribute, kAXDescriptionAttribute].contains { normText(text(e, $0)) == normText(args[3]) }
                    : text(e, "AXIdentifier") == args[3]
                if ok { hit = e }
                return ok
            }
        }
    }
    guard let hit else { print("set '\(args[3])': not found"); exit(5) }
    let now = (attr(hit, kAXValueAttribute) as? NSNumber)?.intValue ?? -1
    var status = AXError.success
    if now != Int(args[4]) { status = AXUIElementPerformAction(hit, kAXPressAction as CFString); usleep(500_000) }
    let after = (attr(hit, kAXValueAttribute) as? NSNumber)?.intValue ?? -1
    print("set '\(args[3])' \(now) -> \(after) (wanted \(args[4])) : \(status.rawValue)")
    exit(after == Int(args[4]) ? 0 : 4)
case "waitfor":
    // L3h: wait until TEXT (an id, or a title/description/value/placeholder) is in the app's windows, SECS at most.
    // SwiftUI can publish a view late: an empty AXOpaqueProviderGroup after « Ce Mac » (J-0768, J-0778).
    let want = normText(args[3]), until = Date().addingTimeInterval(Double(args.count > 4 ? args[4] : "12") ?? 12)
    let wa = app(args[2])
    repeat {
        for w in (attr(wa, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            var budget = 8000
            if walk(w, budget: &budget, visit: { e, _ in
                text(e, "AXIdentifier") == args[3] || [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
                    .contains { normText(text(e, $0)).contains(want) } || normText((attr(e, kAXValueAttribute) as? String) ?? "").contains(want)
            }) { print("waitfor '\(args[3])': found"); exit(0) }
        }
        usleep(500_000)
    } while Date() < until
    print("waitfor '\(args[3])': not found"); exit(5)
case "setdate":
    // L3h: set a date picker (AXDateTimeArea whose title or description is LABEL) to DAYS from today at HOUR:00.
    // The Atelier reads a short closed period (yesterday) instead of today, which recording keeps changing (J-0522).
    let label = normText(args[3]), days = Int(args[4]) ?? 0, hour = Int(args.count > 5 ? args[5] : "0") ?? 0
    var hit: AXUIElement?
    for root in roots(args[2]) where hit == nil {
        var budget = 6000
        _ = walk(root, budget: &budget) { e, _ in
            let ok = text(e, kAXRoleAttribute) == "AXDateTimeArea"
                && [kAXTitleAttribute, kAXDescriptionAttribute].contains { normText(text(e, $0)) == label }
            if ok { hit = e }
            return ok
        }
    }
    guard let hit else { print("setdate '\(args[3])': not found"); exit(5) }
    let cal = Calendar.current
    let day = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: Date()))!
    let when = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    let st = AXUIElementSetAttributeValue(hit, kAXValueAttribute as CFString, when as CFDate).rawValue
    usleep(500_000)
    let got = attr(hit, kAXValueAttribute) as? Date
    print("setdate '\(args[3])' -> \(when) : \(st) now=\(got.map { "\($0)" } ?? "nil")")
    exit(got.map { abs($0.timeIntervalSince(when)) < 61 } == true ? 0 : 4)
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
    // L3g, strict click: 10 = no effect (changed=0 and EXPECT absent), 11 = not a control (Group/Heading/StaticText
    // with no actionable ancestor or child of the same label or id), 12 = disabled. EXPECT (8th argument, optional):
    // an id or a text that must be in the tree after the click (the row's effect check).
    // L3h: EXPECT terms joined by " && ": ID or TEXT; LABEL=0|1 (a checkbox's AXValue); app:BUNDLE=TEXT (a window of
    // BUNDLE titled TEXT, Finder opened by the press). Also checked by shortcut/escape when changed=0.
    // PICK (9th argument): a click opens the target's menu and chooses PICK; changed covers the whole sequence.
    let (bundle, action, mode, role, needle) = (args[2], args[3], args[4], args[5], args[6])
    let scrolls = Int(args.count > 7 ? args[7] : "3") ?? 3
    let expect = args.count > 8 ? args[8] : ""
    let pick = normText(args.count > 9 ? args[9] : "")
    let a = app(bundle)
    func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{a0}", with: " ").replacingOccurrences(of: "\u{202f}", with: " ")
            .replacingOccurrences(of: "'", with: "’")
    }
    let n = norm(needle)
    func texts(_ e: AXUIElement) -> [String] {
        var t = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].map { norm(text(e, $0)) }
        if let v = attr(e, kAXValueAttribute) as? String { t.append(norm(v)) }
        // L3e: an unlabeled field is known by its placeholder (« Ajouter un site · exemple.fr », J-0847).
        if textRoles.contains(text(e, kAXRoleAttribute)) { t.append(norm(text(e, kAXPlaceholderValueAttribute))) }
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
        // L3g: the frontmost app (Finder, System Settings opened by the press) and numeric values and enabled
        // states (checkboxes, steppers), which describe() leaves out.
        h.combine(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        for w in (attr(a, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            _ = walk(w, budget: &budget) { e, _ in
                h.combine(describe(e))
                if let v = attr(e, kAXValueAttribute) as? NSNumber { h.combine(v.doubleValue) }
                if let en = attr(e, kAXEnabledAttribute) as? Bool { h.combine(en) }
                return false
            }
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
    guard var e = el else { print("found=0"); exit(5) }
    print("found=1"); print("element=\(describe(e))")
    // L3g: a click on a label or a container is not a click on a control. Take the actionable ancestor (6 levels)
    // or child with the same label or id; none: not-a-control.
    if action == "click" && ["AXGroup", "AXHeading", "AXStaticText"].contains(text(e, kAXRoleAttribute)) {
        func actionable(_ x: AXUIElement) -> Bool {
            var names: CFArray?
            guard AXUIElementCopyActionNames(x, &names) == .success, let list = names as? [String] else { return false }
            return list.contains(kAXPressAction) && !["AXGroup", "AXHeading", "AXStaticText", "AXWindow", "AXSheet",
                "AXScrollArea", "AXApplication"].contains(text(x, kAXRoleAttribute))
        }
        let keys = Set(texts(e).filter { !$0.isEmpty } + (n.isEmpty || mode == "dialog" ? [] : [n]))
        let id0 = text(e, "AXIdentifier")
        func same(_ x: AXUIElement) -> Bool {
            let id = text(x, "AXIdentifier")
            if !id.isEmpty && (id == id0 || (mode == "id" && id == needle) || (mode == "idprefix" && id.hasPrefix(needle))) { return true }
            return texts(x).contains { t in !t.isEmpty && keys.contains { t == $0 || t.contains($0) } }
        }
        var control: AXUIElement?
        var up = attr(e, kAXParentAttribute).map { $0 as! AXUIElement }
        for _ in 0..<6 {
            guard let p = up else { break }
            if actionable(p) && same(p) { control = p; break }
            up = attr(p, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        if control == nil {
            var budget = 400
            _ = walk(e, budget: &budget) { x, d in
                if d > 0 && actionable(x) && same(x) { control = x; return true }
                return false
            }
        }
        guard let c = control else { print("not_a_control=\(text(e, kAXRoleAttribute))"); exit(11) }
        e = c; print("control=\(describe(e))")
    }
    let r = text(e, kAXRoleAttribute)
    func value() -> String { attr(e, kAXValueAttribute).map { "\($0)" } ?? "nil" }
    func press() -> Int32 { AXUIElementPerformAction(e, kAXPressAction as CFString).rawValue }
    func okStatus(_ s: Int32) -> Bool { s == 0 || s == -25204 }
    var pass = true
    if action == "click" {
        let en = attr(e, kAXEnabledAttribute) as? Bool
        print("enabled=\(en.map { $0 ? 1 : 0 }.map(String.init) ?? "-")")
        if en == false { exit(12) }
    }
    func expected() -> Bool {  // The row's effect check: every EXPECT term holds in the tree after the action.
        guard !expect.isEmpty else { return false }
        return expect.components(separatedBy: " && ").allSatisfy { term in
            if term.hasPrefix("app:"), let eq = term.firstIndex(of: "=") {
                let b = String(term[term.index(term.startIndex, offsetBy: 4)..<eq]), t = norm(String(term[term.index(after: eq)...]))
                for _ in 0..<6 {
                    if let run = NSRunningApplication.runningApplications(withBundleIdentifier: b).first {
                        let wins = (attr(AXUIElementCreateApplication(run.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]) ?? []
                        if wins.contains(where: { norm(text($0, kAXTitleAttribute)).contains(t) }) { return true }
                    }
                    usleep(500_000)
                }
                return false
            }
            if let eq = term.lastIndex(of: "="), let want = Int(term[term.index(after: eq)...]) {
                let label = norm(String(term[..<eq]))
                return searchRoots().contains { root in
                    var budget = 8000
                    return walk(root, budget: &budget) { x, _ in
                        toggleRoles.contains(text(x, kAXRoleAttribute)) && (attr(x, kAXValueAttribute) as? NSNumber)?.intValue == want
                            && [kAXTitleAttribute, kAXDescriptionAttribute].contains { norm(text(x, $0)) == label }
                    }
                }
            }
            let x = norm(term)
            return searchRoots().contains { root in
                var budget = 8000
                return walk(root, budget: &budget) { el, _ in text(el, "AXIdentifier") == term || texts(el).contains { $0.contains(x) } }
            }
        }
    }
    switch action {
    case "click" where r == "AXSlider":
        let s = AXUIElementPerformAction(e, kAXIncrementAction as CFString).rawValue; usleep(400_000)
        _ = AXUIElementPerformAction(e, kAXDecrementAction as CFString)
        print("increment=\(s)")
        pass = okStatus(s)
    case "click" where !pick.isEmpty:
        let before = signature()
        guard pickItem(bundle, e, pick) else { exit(5) }
        usleep(1_200_000)
        let changed = before != signature()
        print("changed=\(changed ? 1 : 0)")
        if !changed {
            let fx = expected()
            if !expect.isEmpty { print("expect=\(expect) present=\(fx ? 1 : 0)") }
            if !fx { exit(10) }
        }
    case "click":
        let before = signature(); let s = press(); usleep(1_200_000)
        let changed = before != signature()
        print("press=\(s)"); print("changed=\(changed ? 1 : 0)")
        guard okStatus(s) else { exit(1) }
        if !changed {
            let fx = expected()
            if !expect.isEmpty { print("expect=\(expect) present=\(fx ? 1 : 0)") }
            if !fx { exit(10) }
        }
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
        if !changed && !expect.isEmpty { pass = expected(); print("expect=\(expect) present=\(pass ? 1 : 0)") }
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
