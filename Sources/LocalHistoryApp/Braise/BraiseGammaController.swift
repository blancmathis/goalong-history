#if os(macOS)
import AppKit
import CoreGraphics
import Darwin
import BraiseCore

struct GammaTable: Codable, Equatable {
    let displayID: UInt32
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    var isValid: Bool {
        (2...16384).contains(red.count) && red.count == green.count && green.count == blue.count
            && (red + green + blue).allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    /// This table with each channel multiplied by its gain, clamped to 0...1.
    func scaled(_ gains: Gains) -> GammaTable {
        GammaTable(displayID: displayID, red: red.map { max(0, min(1, $0 * Float(gains.r))) },
                   green: green.map { max(0, min(1, $0 * Float(gains.g))) }, blue: blue.map { max(0, min(1, $0 * Float(gains.b))) })
    }
}
struct Gains: Equatable {
    var r: Double; var g: Double; var b: Double
    static let neutral = Gains(r: 1, g: 1, b: 1)
    static func blend(_ a: Gains, _ b: Gains, _ t: Double) -> Gains {
        Gains(r:a.r+(b.r-a.r)*t, g:a.g+(b.g-a.g)*t, b:a.b+(b.b-a.b)*t)
    }
}
enum GammaError: LocalizedError {
    case unsupported, rejected, watchdog
    var errorDescription: String? {
        switch self {
        case .unsupported: return "Cet écran ne permet pas le contrôle couleur. Aucun filtre n’a été appliqué."
        case .rejected: return "macOS n’a pas conservé le filtre. Les couleurs ont été rétablies. Vérifiez les autres applications de couleur ou le mode HDR."
        case .watchdog: return "La sécurité de restauration n’a pas pu démarrer. Le filtre reste désactivé."
        }
    }
}

/// Only public CoreGraphics APIs. No overlay, accessibility access, display
/// capture, privileged helper, or hardware-brightness changes.
protocol BraiseGammaDriving: AnyObject {
    var onError: ((String) -> Void)? { get set }
    var onDisplays: ((Int) -> Void)? { get set }
    func set(active: Bool, intensity: Double, brightness: Double, animated: Bool)
    func restore()
    func checkAfterSystemChange()
    /// Restores the tables a crashed run left behind (its guardian died too). Called once per controller start.
    func recoverPending()
    func probe() -> [[String: Any]]
    func onlineDisplayCount() -> Int
}
extension BraiseGammaDriving {
    func recoverPending() {}
    func probe() -> [[String: Any]] { [] }
    func onlineDisplayCount() -> Int { 0 }
}

/// The guardian of one activation: closing it (or the death of this process) restores the saved tables.
protocol BraiseGuardian: AnyObject { func disarm() }

/// The screens and their tables. The only seam between the gamma logic and the system: tests use a fake
/// (BraiseModuleTests, RedScreenGuaranteeTests); `CoreGraphicsDisplays` is the real one.
protocol GammaDisplayDriving: AnyObject {
    func displays() -> [UInt32]
    func read(_ display: UInt32) throws -> GammaTable
    func write(_ table: GammaTable) -> Bool
    /// The system's own tables, when a saved one cannot be written back.
    func restoreSystemColors()
    func startGuardian(recoveryURL: URL) throws -> BraiseGuardian
}

/// The real screens. Under XCTest outside CI it is inert and fails the running test (GoalongHeadlessTestSupport):
/// a test never changes the colors of the Mac it runs on.
final class CoreGraphicsDisplays: GammaDisplayDriving {
    static let builtUnderTests = Notification.Name("ai.goalong.tests.realGammaDriverBuilt")
    private let inert: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        inert = Self.refusesUnderTests(environment: environment, xctestLoaded: NSClassFromString("XCTestCase") != nil)
        if inert {
            FileHandle.standardError.write(Data("[headless-tests] real gamma driver built under XCTest outside CI: inert\n".utf8))
            NotificationCenter.default.post(name: Self.builtUnderTests, object: nil)
        }
    }
    /// A test may build the real driver only on GitHub Actions (its virtual screen); never on a person's Mac.
    static func refusesUnderTests(environment: [String: String], xctestLoaded: Bool) -> Bool {
        let underTests = xctestLoaded || environment["XCTestConfigurationFilePath"] != nil
        return underTests && environment["GITHUB_ACTIONS"] != "true"
    }
    func displays() -> [UInt32] {
        guard !inert else { return [] }
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating:0,count:Int(count))
        guard CGGetOnlineDisplayList(count,&ids,&count) == .success else { return [] }
        return Array(ids.prefix(Int(count))).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }
    func read(_ display: UInt32) throws -> GammaTable {
        guard !inert else { throw GammaError.unsupported }
        let capacity = CGDisplayGammaTableCapacity(display)
        guard capacity > 0, capacity <= 16384 else { throw GammaError.unsupported }
        var r = [Float](repeating: 0, count: Int(capacity)), g = r, b = r
        var count: UInt32 = 0
        let result = CGGetDisplayTransferByTable(display, capacity, &r, &g, &b, &count)
        guard result == .success, count > 1, count <= capacity else { throw GammaError.unsupported }
        let table = GammaTable(displayID: display, red: Array(r.prefix(Int(count))), green: Array(g.prefix(Int(count))), blue: Array(b.prefix(Int(count))))
        guard table.isValid else { throw GammaError.unsupported }; return table
    }
    func write(_ table: GammaTable) -> Bool {
        guard !inert, table.isValid else { return false }
        return CGSetDisplayTransferByTable(table.displayID, UInt32(table.red.count), table.red, table.green, table.blue) == .success
    }
    func restoreSystemColors() { if !inert { CGDisplayRestoreColorSyncSettings() } }
    func startGuardian(recoveryURL: URL) throws -> BraiseGuardian {
        guard !inert else { throw GammaError.watchdog }
        let process = Process(), pipe = Pipe(), ready = Pipe()
        guard let executable = Bundle.main.executableURL else { throw GammaError.watchdog }
        process.executableURL = executable
        process.arguments = ["--braise-guardian", recoveryURL.path]
        process.environment = [:]
        process.standardInput = pipe
        process.standardOutput = ready
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw GammaError.watchdog }
        pipe.fileHandleForReading.closeFile()
        ready.fileHandleForWriting.closeFile()
        var descriptor = pollfd(fd: ready.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 2000) > 0,
              (try? ready.fileHandleForReading.read(upToCount: 1)) == Data([0x42]) else {
            try? pipe.fileHandleForWriting.close(); process.terminate(); throw GammaError.watchdog
        }
        try? ready.fileHandleForReading.close()
        return PipeGuardian(process: process, pipe: pipe)
    }
    private final class PipeGuardian: BraiseGuardian {
        private var process: Process?
        private var pipe: Pipe?
        init(process: Process, pipe: Pipe) { self.process = process; self.pipe = pipe }
        func disarm() { try? pipe?.fileHandleForWriting.close(); pipe = nil; process = nil }
    }
}

final class GammaController: BraiseGammaDriving {
    private var originals: [GammaTable] = []
    private var guardian: BraiseGuardian?
    private var animation: Timer?
    private var gains = Gains.neutral
    private var target = Gains.neutral
    private var wantedActive = false
    var onError: ((String) -> Void)?
    var onDisplays: ((Int) -> Void)?
    private let directory: URL
    private let screens: GammaDisplayDriving
    private(set) var recoveryURL: URL

    init(directory: URL, screens: GammaDisplayDriving = CoreGraphicsDisplays()) {
        self.directory = directory; self.screens = screens
        recoveryURL = directory.appendingPathComponent("display-recovery.json")
    }

    private func arm() throws {
        let ids = screens.displays()
        guard !ids.isEmpty, ids.count <= 32 else { throw GammaError.unsupported }
        // Fail closed for all screens rather than silently leaving one unfiltered.
        originals = try ids.map { try screens.read($0) }
        recoveryURL = directory.appendingPathComponent("display-recovery-" + UUID().uuidString + ".json")
        try BraiseStore.write(JSONEncoder().encode(originals), to: recoveryURL)
        do { guardian = try screens.startGuardian(recoveryURL: recoveryURL) }
        catch { originals = []; try? FileManager.default.removeItem(at: recoveryURL); throw GammaError.watchdog }
        onDisplays?(originals.count)
    }
    private func disarm() {
        try? FileManager.default.removeItem(at:recoveryURL)
        guardian?.disarm(); guardian = nil
    }
    func set(active: Bool, intensity: Double, brightness: Double, animated: Bool = true) {
        let channels = ChannelGains(intensity:intensity,brightness:brightness)
        let next = active ? Gains(r:channels.red,g:channels.green,b:channels.blue) : .neutral
        if wantedActive == active, next == target, (!active || !originals.isEmpty) { return }
        animation?.invalidate(); animation = nil
        wantedActive = active; target = next
        if active && originals.isEmpty {
            do { try arm(); gains = .neutral }
            catch { originals = []; disarm(); wantedActive = false; target = .neutral; onError?(error.localizedDescription); return }
        }
        guard !originals.isEmpty else { return }
        guard animated else { commit(next); finish(); return }
        let from = gains, begin = Date()
        animation = Timer(timeInterval:1.0/30, repeats:true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, Date().timeIntervalSince(begin) / 0.38)
            let smooth = t*t*(3-2*t)
            self.commit(Gains.blend(from,next,smooth))
            if t >= 1 { timer.invalidate(); self.animation = nil; self.finish() }
        }
        RunLoop.main.add(animation!, forMode:.common)
    }
    private func commit(_ next: Gains) {
        guard !originals.isEmpty else { return }
        if !originals.allSatisfy({ screens.write($0.scaled(next)) }) { fail(); return }
        gains = next
    }
    private func finish() {
        if !wantedActive { restore() }
        else if !verify() { fail() }
    }
    func verify() -> Bool {
        guard !originals.isEmpty else { return !wantedActive }
        for table in originals {
            guard let current = try? screens.read(table.displayID),
                  let r = current.red.last, let g = current.green.last, let b = current.blue.last,
                  let br = table.red.last, let bg = table.green.last, let bb = table.blue.last else { return false }
            let error = max(abs(Double(r)-Double(br)*target.r), abs(Double(g)-Double(bg)*target.g), abs(Double(b)-Double(bb)*target.b))
            if error > 0.025 { return false }
        }
        return true
    }
    /// Red off: returns at once, no table is read or written.
    func checkAfterSystemChange() {
        guard wantedActive, animation == nil else { return }
        let ids = Set(screens.displays()), previous = Set(originals.map(\.displayID))
        if ids != previous {
            // Do not briefly restore existing screens when an external monitor appears.
            do {
                var updated = originals.filter { ids.contains($0.displayID) }
                for id in ids.subtracting(previous).sorted() { updated.append(try screens.read(id)) }
                guard !updated.isEmpty else { return }
                originals = updated
                try BraiseStore.write(JSONEncoder().encode(originals), to: recoveryURL)
                onDisplays?(originals.count)
            } catch { fail(); return }
        }
        if !verify() {
            commit(target)
            if !verify() { fail() }
        }
    }
    private func fail() { restore(); onError?(GammaError.rejected.localizedDescription) }
    func restore() {
        animation?.invalidate(); animation = nil
        if !originals.isEmpty {
            let restored = originals.map { screens.write($0) }.allSatisfy { $0 }
            if !restored { screens.restoreSystemColors() }
        }
        originals = []; gains = .neutral; target = .neutral; wantedActive = false
        disarm()
    }
    func recoverPending() { Self.recoverPending(in: directory, screens: screens) }
    func onlineDisplayCount() -> Int { screens.displays().count }
    func probe() -> [[String: Any]] {
        screens.displays().map { id in
            guard let table = try? screens.read(id) else { return ["display": id, "error": "gamma table unavailable"] }
            return ["display": id, "samples": table.red.count, "redMax": table.red.max() ?? 0,
                    "greenMax": table.green.max() ?? 0, "blueMax": table.blue.max() ?? 0]
        }
    }
    static func recover(from url: URL, screens: GammaDisplayDriving) {
        guard let data = try? BraiseStore.read(url, maximumBytes: 8 * 1024 * 1024),
              let tables = try? JSONDecoder().decode([GammaTable].self,from:data),
              !tables.isEmpty, tables.count <= 32, tables.allSatisfy({ $0.isValid }) else { return }
        let results = tables.map { screens.write($0) }
        if results.contains(false) { screens.restoreSystemColors() }
        try? FileManager.default.removeItem(at:url)
    }
    static func recoverPending(in directory: URL, screens: GammaDisplayDriving) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files.prefix(64) where file.lastPathComponent.hasPrefix("display-recovery") && file.pathExtension == "json" {
            recover(from: file, screens: screens)
        }
    }
    static func guardianMain(path: String) -> Never {
        // A pipe held by the UI process closes on normal termination AND SIGKILL.
        // No polling timer: the watchdog sleeps in this blocking read.
        try? FileHandle.standardOutput.write(contentsOf: Data([0x42]))
        try? FileHandle.standardOutput.close()
        _ = FileHandle.standardInput.readDataToEndOfFile()
        recover(from:URL(fileURLWithPath:path), screens: CoreGraphicsDisplays())
        exit(0)
    }
}

#endif
