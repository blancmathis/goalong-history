#if os(macOS)
    import XCTest
    @testable import LocalHistoryApp

    /// T-057 D1 §1: each capture read the properties of every running application on the main
    /// thread (LaunchServices stalls of 8–25 s). The catalogue must read them only on change and
    /// return exactly what a live read returns.
    final class RunningApplicationCatalogTests: XCTestCase {
        private final class CountingSource: RunningApplicationSource {
            var applications: [pid_t: ForegroundAXApplication] = [:]
            var enumerations = 0
            var propertyReads = 0
            var onChange: (() -> Void)?
            var onActivate: ((pid_t) -> Void)?

            func currentProcessIdentifiers() -> [pid_t] {
                enumerations += 1
                return applications.keys.sorted()
            }

            func application(for processIdentifier: pid_t) -> ForegroundAXApplication? {
                propertyReads += 1
                return applications[processIdentifier]
            }

            func startObserving(onChange: @escaping () -> Void, onActivate: @escaping (pid_t) -> Void) {
                self.onChange = onChange
                self.onActivate = onActivate
            }

            /// What the former per-capture code built: every app read live.
            var liveRead: [pid_t: ForegroundAXApplication] { applications }

            func launch(_ pid: pid_t, _ name: String, regular: Bool = true) {
                applications[pid] = ForegroundAXApplication(
                    pid: pid, name: name, bundleIdentifier: "test.\(name)",
                    instanceStartedAt: Date(timeIntervalSince1970: Double(pid)), regular: regular)
                onChange?()
            }

            func quit(_ pid: pid_t) {
                applications.removeValue(forKey: pid)
                onChange?()
            }
        }

        func testHundredCapturesReadEachApplicationOnceInSteadyState() {
            let source = CountingSource()
            for pid in 100..<160 { source.launch(pid_t(pid), "app\(pid)") }
            let catalog = RunningApplicationCatalog(source: source)

            XCTAssertEqual(catalog.snapshot(), source.liveRead)
            let enumerationsAfterWarmUp = source.enumerations
            let readsAfterWarmUp = source.propertyReads
            XCTAssertEqual(enumerationsAfterWarmUp, 1)
            XCTAssertEqual(readsAfterWarmUp, 60)

            for _ in 0..<100 { XCTAssertEqual(catalog.snapshot(), source.liveRead) }
            XCTAssertEqual(source.enumerations - enumerationsAfterWarmUp, 0, "full enumerations in steady state")
            XCTAssertEqual(source.propertyReads - readsAfterWarmUp, 0, "per-app property reads in steady state")
        }

        func testCatalogMatchesLiveReadAcrossLaunchQuitAndActivation() {
            let source = CountingSource()
            source.launch(1, "finder")
            source.launch(2, "helper", regular: false)
            let catalog = RunningApplicationCatalog(source: source)
            XCTAssertEqual(catalog.snapshot(), source.liveRead)

            source.launch(3, "editor")
            XCTAssertEqual(catalog.snapshot(), source.liveRead)
            let reads = source.propertyReads
            source.quit(1)
            XCTAssertEqual(catalog.snapshot(), source.liveRead)
            XCTAssertEqual(source.propertyReads, reads, "a quit reads no properties")

            // An accessory app becomes regular and is activated: its entry is re-read.
            source.applications[2] = ForegroundAXApplication(
                pid: 2, name: "helper", bundleIdentifier: "test.helper",
                instanceStartedAt: Date(timeIntervalSince1970: 2), regular: true)
            source.onActivate?(2)
            XCTAssertEqual(catalog.snapshot(), source.liveRead)

            // The frontmost app read live by the caller refreshes its cached entry too.
            let renamed = ForegroundAXApplication(
                pid: 3, name: "editor 2", bundleIdentifier: "test.editor",
                instanceStartedAt: Date(timeIntervalSince1970: 3))
            source.applications[3] = renamed
            XCTAssertEqual(catalog.snapshot(frontmost: renamed), source.liveRead)
            XCTAssertEqual(catalog.snapshot(), source.liveRead)
        }
    }
#endif
