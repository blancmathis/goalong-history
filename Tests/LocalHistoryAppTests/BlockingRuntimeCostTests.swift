#if os(macOS)
import AppKit
import XCTest
@testable import LocalHistoryApp

/// Opt-in cost of the module once on: one blocking sample read from a real, already open browser
/// (never brought forward), and the controller's work per sample.
/// `GOALONG_BLOCKING_COST=1 swift test --filter BlockingRuntimeCostTests`
final class BlockingRuntimeCostTests: XCTestCase {
    @MainActor func testSampleCost() throws {
        guard ProcessInfo.processInfo.environment["GOALONG_BLOCKING_COST"] != nil else {
            throw XCTSkip("Opt-in measurement on this Mac")
        }
        let config = ConfigManager()
        let permissions = PermissionManager()
        let provider = ContextProvider(configManager: config, permissions: permissions)
        let browsers = config.config.browserBundleIdentifiers
        let targets = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && BlockingRules.isKnownBrowser($0.bundleIdentifier, configured: browsers)
        }
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !BlockingRules.isKnownBrowser($0.bundleIdentifier, configured: browsers)
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let count = 400
        for (label, app) in [("browser", targets.first), ("app", others.first)] {
            guard let app else { continue }
            _ = provider.captureBlocking(of: app)
            let cpu = cpuSeconds(), wall = Date()
            var observation: BlockingObservation?
            for _ in 0..<count { observation = provider.captureBlocking(of: app) }
            let perSample = (cpuSeconds() - cpu) / Double(count) * 1_000
            print("BLOCKING_COST trusted=\(AXIsProcessTrusted()) session=\(observation?.sessionAvailable == true) frame=\(observation?.windowFrame != nil) private=\(observation?.privateWindow == true) browsers=\(targets.compactMap(\.bundleIdentifier))")
            print(String(format: "BLOCKING_COST sample %@ %@ cpu=%.2f ms wall=%.2f ms url=%@ browser=%@", label,
                         app.bundleIdentifier ?? "?", perSample, Date().timeIntervalSince(wall) / Double(count) * 1_000,
                         observation?.url == nil ? "no" : "yes", observation?.isBrowser == true ? "yes" : "no"))
        }

        // Controller work per sample, at the real cadence (one sample every 0.75 s).
        var now = Date()
        let list = BlockList(name: "Mesure", sites: ["youtube.com", "x.com", "reddit.com"].map { BlockSiteRule(pattern: $0) },
                             quotaMinutesPerDay: 30)
        let before = footprint()
        let controller = BlockingController(document: BlockingDocument(lists: [list]), clock: { now })
        controller.start(listIDs: [list.id], until: now.addingTimeInterval(3_600), lock: .free)
        let sample = BlockingObservation(bundleIdentifier: "com.apple.Safari", pid: 1, windowFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                         isBrowser: true, url: "example.org/page", privateWindow: false, at: now)
        let cpu = cpuSeconds()
        for _ in 0..<count {
            now = now.addingTimeInterval(0.75)
            var value = sample; value.at = now
            controller.observe(value)
        }
        print(String(format: "BLOCKING_COST controller cpu=%.3f ms per sample, footprint +%.1f MB",
                     (cpuSeconds() - cpu) / Double(count) * 1_000, Double(footprint() - before) / 1_048_576))
    }

    private func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size) }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
#endif
