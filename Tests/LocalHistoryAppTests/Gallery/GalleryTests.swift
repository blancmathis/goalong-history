#if os(macOS)
import AppKit
import Foundation
import GoalongHeadlessTestSupport
import XCTest
@testable import LocalHistoryApp

/// Opt-in gallery renderer, launched by `make gallery` (scripts/gallery.py), one process per shard:
/// `GOALONG_GALLERY=<run dir> GOALONG_GALLERY_SHARD=i/N [GOALONG_GALLERY_ONLY=prefixes]`.
/// Writes `png/<surface>/<state>--<theme>[--<size>].png`, one JSON line per image in `results-<i>.jsonl` and the
/// screen facts in `env-<i>.json`. A relaunched shard skips the images already in its results file.
final class GalleryTests: XCTestCase {
    static let watchdogSeconds: TimeInterval = 10

    @MainActor func testRenderGallery() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["GOALONG_GALLERY"], !output.isEmpty else {
            throw XCTSkip("Opt-in gallery render: make gallery")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let homes = [home.path, environment["HOME"] ?? "", environment["CFFIXED_USER_HOME"] ?? ""]
        guard homes.allSatisfy({ $0.hasPrefix("/tmp/goalong-gallery-") || $0.hasPrefix("/private/tmp/goalong-gallery-") }) else {
            XCTFail("gallery: refused, HOME is not a gallery HOME (\(homes.joined(separator: ", ")))")
            return
        }
        let (shard, count) = Self.shard(environment["GOALONG_GALLERY_SHARD"])
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        GalleryRenderer.prepareApplication()
        let entries = GalleryCatalog.filtered(environment["GOALONG_GALLERY_ONLY"])
            .filter { GalleryEntry.shard(of: $0.id, count: count) == shard }
        try writeEnvironment(directory.appendingPathComponent("env-\(shard).json"), shard: shard, count: count)

        let results = GalleryResults(url: directory.appendingPathComponent("results-\(shard).jsonl"))
        let done = results.keys()
        let watchdog = GalleryWatchdog(seconds: Self.watchdogSeconds, results: results)
        defer { watchdog.stop() }
        for entry in entries {
            for size in entry.sizes {
                for theme in entry.themes {
                    let file = Self.file(entry, theme: theme, size: size)
                    if done.contains(file) { continue }
                    let base: [String: Any] = ["key": file, "id": entry.id, "surface": entry.surface, "state": entry.state,
                                               "theme": theme.rawValue, "size": size.label ?? "", "file": file,
                                               "source": entry.source, "note": entry.note ?? "", "shard": shard]
                    watchdog.arm(base)
                    let started = Date()
                    var line = base
                    autoreleasepool {
                        line.merge(renderOne(entry, theme: theme, size: size, file: file, directory: directory)) { $1 }
                    }
                    line["ms"] = Int(Date().timeIntervalSince(started) * 1_000)
                    watchdog.disarm()
                    results.append(line)
                }
            }
        }
    }

    /// One image: fresh suite and data, guards on, render, guards off, PNG written. Never throws.
    @MainActor private func renderOne(_ entry: GalleryEntry, theme: GalleryTheme, size: GallerySize, file: String,
                                      directory: URL) -> [String: Any] {
        let ctx = GalleryContext()
        var line: [String: Any] = [:]
        do {
            try GalleryStateReset.all(home: ctx.home)
        } catch {
            return ["status": GalleryImage.Status.failed.rawValue, "detail": "\(error)"]
        }
        GalleryGuardReport.begin()
        var image: GalleryImage?
        var failure: String?
        do { image = try GalleryRenderer.render(entry, theme: theme, size: size, ctx: ctx) } catch { failure = "\(error)" }
        ctx.finish()
        let report = GalleryGuardReport.take()
        guard var image else {
            return ["status": GalleryImage.Status.failed.rawValue, "detail": failure ?? "no image"]
        }
        if let status = report.status, image.status == .ok || status == .failed {
            image.status = status; image.detail = report.summary
            if let stack = report.standardStack, !stack.isEmpty {
                line["standardStack"] = String(stack.split(separator: "\n").prefix(14).joined(separator: "\n"))
            }
        }
        let url = directory.appendingPathComponent("png").appendingPathComponent(file)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try image.png.write(to: url, options: .atomic)
        } catch {
            return ["status": GalleryImage.Status.failed.rawValue, "detail": "PNG not written: \(error)"]
        }
        line["status"] = image.status.rawValue
        line["detail"] = image.detail ?? ""
        line["hash"] = image.pixelHash
        line["pointWidth"] = Int(image.pointSize.width.rounded()); line["pointHeight"] = Int(image.pointSize.height.rounded())
        line["pixelWidth"] = image.pixelSize.width; line["pixelHeight"] = image.pixelSize.height
        line["scale"] = Double(image.backingScale)
        return line
    }

    static func file(_ entry: GalleryEntry, theme: GalleryTheme, size: GallerySize) -> String {
        "\(entry.surface)/\(entry.state)--\(theme.rawValue)" + (size.label.map { "--\($0)" } ?? "") + ".png"
    }

    static func shard(_ raw: String?) -> (Int, Int) {
        let parts = (raw ?? "0/1").split(separator: "/").compactMap { Int($0) }
        guard parts.count == 2, parts[1] > 0, (0..<parts[1]).contains(parts[0]) else { return (0, 1) }
        return (parts[0], parts[1])
    }

    @MainActor private func writeEnvironment(_ url: URL, shard: Int, count: Int) throws {
        let probe = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled],
                             backing: .buffered, defer: true)
        probe.isReleasedWhenClosed = false
        defer { probe.close() }
        let screen = NSScreen.main
        let info: [String: Any] = [
            "shard": shard, "shards": count,
            "screenWidth": Double(screen?.frame.width ?? 0), "screenHeight": Double(screen?.frame.height ?? 0),
            "screenScale": Double(screen?.backingScaleFactor ?? 0), "windowScale": Double(probe.backingScaleFactor),
            "locale": Locale.current.identifier, "timeZone": TimeZone.current.identifier,
            "clock": GalleryClock.now.timeIntervalSince1970,
            "clockProbe": GalleryClock.probeDays,
            "guards": GoalongGalleryGuardsInstalled(),
        ]
        try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
}

/// Appends one JSON object per line; safe from the watchdog's queue.
final class GalleryResults: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    func keys() -> Set<String> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) .flatMap { ($0 as? [String: Any])?["key"] as? String }
        })
    }

    func append(_ line: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.synchronize()
    }
}

/// 10 s per image. On expiry it records the image as `timeout` and ends the process (exit 3); the script relaunches
/// the shard, which resumes after this image.
final class GalleryWatchdog: @unchecked Sendable {
    private let seconds: TimeInterval
    private let results: GalleryResults
    private let queue = DispatchQueue(label: "goalong.gallery.watchdog")
    private var timer: DispatchSourceTimer?
    private var current: [String: Any]?

    init(seconds: TimeInterval, results: GalleryResults) { self.seconds = seconds; self.results = results }

    func arm(_ line: [String: Any]) {
        queue.sync {
            timer?.cancel()
            current = line
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + seconds)
            timer.setEventHandler { [weak self] in self?.fire() }
            timer.resume()
            self.timer = timer
        }
    }

    func disarm() { queue.sync { timer?.cancel(); timer = nil; current = nil } }
    func stop() { disarm() }

    private func fire() {
        guard var line = current else { return }
        line["status"] = GalleryImage.Status.timeout.rawValue
        line["detail"] = "no image after \(Int(seconds)) s (watchdog)"
        line["ms"] = Int(seconds * 1_000)
        results.append(line)
        FileHandle.standardError.write(Data("[gallery] timeout: \(line["key"] ?? "?")\n".utf8))
        exit(3)
    }
}
#endif
