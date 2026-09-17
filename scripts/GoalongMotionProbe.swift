import AppKit
import SwiftUI
import CryptoKit
import Darwin

// Runs the real production motion components under an actual AppKit event loop.
// No history, network, permissions, credentials or application services are opened.
@MainActor private final class Fixture: ObservableObject {
    @Published var active = true
    @Published var reduced = false
}

private struct ProbeMarks: View {
    @ObservedObject var fixture: Fixture
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 40) {
                ForEach([24.0, 32.0, 48.0], id: \.self) { size in
                    GoalongActivityMark(isActive: fixture.active, width: size)
                }
            }
            Text("24 / 32 / 48 pt · mouvement système \(systemReduced ? "réduit" : "actif")")
                .font(.system(size: 11)).foregroundStyle(LHTheme.secondaryText)
        }
        .frame(width: 440, height: 200)
        .background(LHTheme.cardBackground)
        .environment(\.goalongReduceMotion, fixture.reduced)
    }
}

@MainActor private final class Probe: NSObject, NSApplicationDelegate {
    let folder: URL
    let fixture = Fixture()
    var window: NSWindow!
    var host: NSHostingController<ProbeMarks>!
    var captures = [String: String]()
    var failures = [String]()
    var activeA = Data(), restA = Data(), reducedA = Data()

    init(folder: URL) { self.folder = folder }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 440, height: 200),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingController(rootView: ProbeMarks(fixture: fixture))
        window.contentViewController = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        after(1.0) {
            print("WINDOW visible=\(self.window.isVisible) occluded=\(!self.window.occlusionState.contains(.visible)) running=\(NSApp.isRunning)")
            self.activeA = try self.capture("native-active-a")
        }
        after(1.45) {
            let activeB = try self.capture("native-active-b")
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.expect(self.activeA == activeB, "System reduced motion keeps active-operation pixels fixed")
            } else {
                self.expect(self.activeA != activeB, "Visible activity changes actual pixels")
            }
            self.fixture.active = false
        }
        after(2.0) { self.restA = try self.capture("native-rest-dark") }
        after(2.4) {
            self.expect(self.restA == (try self.capture("native-rest-dark-stable")), "Idle pixels stay fixed")
            self.fixture.reduced = true
            self.fixture.active = true
        }
        after(2.85) { self.reducedA = try self.capture("native-reduced-dark") }
        after(3.3) {
            self.expect(self.reducedA == (try self.capture("native-reduced-dark-stable")), "Reduced pixels stay fixed")
            self.expect(self.restA == self.reducedA, "Reduced motion uses exact resting geometry")
            self.window.appearance = NSAppearance(named: .aqua)
        }
        after(3.75) {
            _ = try self.capture("native-reduced-light")
            let progress = VStack(alignment: .leading, spacing: 24) {
                ProgressView("Lecture des analyses…")
                ProgressView(value: 0.4, total: 1) { Text("Import mesuré") } currentValueLabel: { Text("40 %") }
                Text("Aucun pourcentage n’est déduit de la phase du logo.").font(.caption)
            }
            .padding(28).frame(width: 520, height: 240)
            .foregroundStyle(LHTheme.text).background(LHTheme.pageBackground)
            .progressViewStyle(GoalongProgressViewStyle())
            .environment(\.goalongReduceMotion, true)
            self.window.contentViewController = NSHostingController(rootView: progress)
            self.window.setContentSize(NSSize(width: 520, height: 240))
        }
        after(4.15) {
            _ = try self.capture("native-progress-semantics", view: self.window.contentView!)
            try self.finish()
        }
    }
    func after(_ delay: Double, _ operation: @escaping @MainActor () throws -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            do { try operation() }
            catch { self.failures.append(String(describing: error)); try? self.finish() }
        }
    }
    func expect(_ passed: Bool, _ message: String) {
        print("\(passed ? "PASS" : "FAIL") \(message)")
        if !passed { failures.append(message) }
    }
    func capture(_ name: String, view explicitView: NSView? = nil) throws -> Data {
        let view = explicitView ?? host.view
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(domain: "GoalongMotionProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "No native bitmap"])
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let pointer = bitmap.bitmapData, let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "GoalongMotionProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "No bitmap pixels"])
        }
        try png.write(to: folder.appendingPathComponent(name + ".png"))
        let pixels = Data(bytes: pointer, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        captures[name] = SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined()
        return pixels
    }
    func finish() throws {
        let report: [String: Any] = [
            "passed": failures.isEmpty, "failures": failures, "capturePixelSHA256": captures,
            "scope": "Actual AppKit event loop; production motion/model/theme compiled directly; isolated synthetic view state",
            "systemReducedMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("native-results.json"))
        window.orderOut(nil)
        window.contentViewController = nil
        Darwin.exit(failures.isEmpty ? 0 : 1)
    }
}

@main private enum GoalongMotionProbe {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: GoalongMotionProbe OUTPUT_DIRECTORY\n", stderr)
            Darwin.exit(2)
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Probe(folder: folder)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
