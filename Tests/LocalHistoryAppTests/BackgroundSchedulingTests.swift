#if os(macOS)
    import ApplicationServices
    import Foundation
    import LocalHistoryCore
    import XCTest
    @testable import LocalHistoryApp

    final class BackgroundSchedulingTests: XCTestCase {
        func testBrowserProcessCacheIsBoundedAndUsesLRUEviction() {
            var cache = BoundedProcessIdentifierCache(capacity: 3)
            cache.insert(1)
            cache.insert(2)
            cache.insert(3)
            cache.insert(1)
            cache.insert(4)

            XCTAssertEqual(cache.count, 3)
            XCTAssertTrue(cache.contains(1))
            XCTAssertFalse(cache.contains(2))
            XCTAssertTrue(cache.contains(3))
            XCTAssertTrue(cache.contains(4))
        }

        func testActivityAnalysisUsesTenMinuteBackgroundCadenceAndNoDisabledRichTimer() {
            XCTAssertEqual(ActivityAnalysisRuntime.backgroundRefreshInterval, 10 * 60)
            XCTAssertFalse(
                ActivityAnalysisRuntime.shouldScheduleRichContextTimer(
                    started: true,
                    enabled: false
                )
            )
            XCTAssertTrue(
                ActivityAnalysisRuntime.shouldScheduleRichContextTimer(
                    started: true,
                    enabled: true
                )
            )
        }

        func testKnownBrowserSkipsRedundantCapabilityTreeProbe() {
            XCTAssertTrue(
                ContextProvider.shouldProbeBrowserCapability(
                    isKnownBrowser: false,
                    capturesURLs: true
                )
            )
            XCTAssertFalse(
                ContextProvider.shouldProbeBrowserCapability(
                    isKnownBrowser: true,
                    capturesURLs: true
                )
            )
            XCTAssertFalse(
                ContextProvider.shouldProbeBrowserCapability(
                    isKnownBrowser: false,
                    capturesURLs: false
                )
            )
        }

        func testAccessibilityValueStormWaitsForQuietButStructuralChangesStayFast() {
            XCTAssertEqual(
                AccessibilityEventMonitor.debounceDelay(
                    for: [kAXValueChangedNotification as String]
                ),
                1.4,
                accuracy: 0.001
            )
            XCTAssertEqual(
                AccessibilityEventMonitor.debounceDelay(
                    for: [
                        kAXValueChangedNotification as String,
                        kAXFocusedWindowChangedNotification as String,
                    ]
                ),
                0.18,
                accuracy: 0.001
            )
        }

        func testAccessibilityObserverSleepsWhileCachedPermissionIsUnavailable() {
            let unavailable = AccessibilityEventMonitor(
                isAccessibilityAvailable: { false },
                onChange: { _ in }
            )
            let available = AccessibilityEventMonitor(
                isAccessibilityAvailable: { true },
                onChange: { _ in }
            )

            XCTAssertFalse(unavailable.canAttemptAttachment)
            XCTAssertTrue(available.canAttemptAttachment)
        }

        func testRecentOwnedSemanticCaptureSuppressesRedundantObservedTreeWalk() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            XCTAssertFalse(
                ActivityAnalysisRuntime.shouldAttemptObservedContextCapture(
                    lastCaptureAt: now.addingTimeInterval(-1.99),
                    now: now
                )
            )
            XCTAssertTrue(
                ActivityAnalysisRuntime.shouldAttemptObservedContextCapture(
                    lastCaptureAt: now.addingTimeInterval(-2),
                    now: now
                )
            )
            XCTAssertTrue(
                ActivityAnalysisRuntime.shouldAttemptObservedContextCapture(
                    lastCaptureAt: nil,
                    now: now
                )
            )
            XCTAssertTrue(
                ActivityAnalysisRuntime.observedContextUsesRecentCaptureCooldown(
                    trigger: "ax:value_changed+selected_text_changed"
                )
            )
            XCTAssertFalse(
                ActivityAnalysisRuntime.observedContextUsesRecentCaptureCooldown(
                    trigger: "ax:focused_element_changed"
                )
            )
        }

        func testContextPollingPreservesConfiguredCadenceDuringActiveInput() {
            XCTAssertEqual(
                ContextMonitor.nextPollInterval(
                    configuredInterval: 0.65,
                    idleSeconds: 2.9,
                    isCapturing: true,
                    suppressionReason: nil,
                    eventDrivenCoverageAvailable: true
                ) ?? -1,
                0.65,
                accuracy: 0.001
            )
        }

        func testContextPollingBacksOffAtRestWithoutExceedingMinuteFreshness() throws {
            let warmIdle = try XCTUnwrap(
                ContextMonitor.nextPollInterval(
                    configuredInterval: 0.65,
                    idleSeconds: 20,
                    isCapturing: true,
                    suppressionReason: nil,
                    eventDrivenCoverageAvailable: true
                ))
            let longIdle = try XCTUnwrap(
                ContextMonitor.nextPollInterval(
                    configuredInterval: 0.65,
                    idleSeconds: 600,
                    isCapturing: true,
                    suppressionReason: nil,
                    eventDrivenCoverageAvailable: true
                ))
            let paused = ContextMonitor.nextPollInterval(
                configuredInterval: 0.65,
                idleSeconds: 600,
                isCapturing: false,
                suppressionReason: nil,
                eventDrivenCoverageAvailable: true
            )

            XCTAssertEqual(warmIdle, 5, accuracy: 0.001)
            XCTAssertEqual(longIdle, 30, accuracy: 0.001)
            XCTAssertNil(paused)
            XCTAssertLessThanOrEqual(max(warmIdle, longIdle), 45)
        }

        func testMissingEventCoverageKeepsConfiguredFallbackCadence() {
            XCTAssertEqual(
                ContextMonitor.nextPollInterval(
                    configuredInterval: 0.65,
                    idleSeconds: 600,
                    isCapturing: true,
                    suppressionReason: nil,
                    eventDrivenCoverageAvailable: false
                ) ?? -1,
                0.65,
                accuracy: 0.001
            )
        }

        func testSensitiveOrUnavailableContextIsRecheckedQuickly() {
            for reason in [
                SuppressionReason.secureInput,
                .accessibilityUnavailable,
                .sessionUnavailable,
            ] {
                XCTAssertLessThanOrEqual(
                    ContextMonitor.nextPollInterval(
                        configuredInterval: 0.65,
                        idleSeconds: 600,
                        isCapturing: true,
                        suppressionReason: reason,
                        eventDrivenCoverageAvailable: true
                    ) ?? .infinity,
                    5
                )
            }
            XCTAssertEqual(
                ContextMonitor.nextPollInterval(
                    configuredInterval: 0.65,
                    idleSeconds: 600,
                    isCapturing: true,
                    suppressionReason: .accessibilityUnavailable,
                    eventDrivenCoverageAvailable: false
                ) ?? -1,
                3,
                accuracy: 0.001
            )
        }

        func testMinuteSealerAlignsFirstWakeupAfterBoundaryGrace() {
            XCTAssertEqual(
                MinuteSealer.secondsUntilNextMinute(
                    now: Date(timeIntervalSince1970: 120)
                ),
                61,
                accuracy: 0.001
            )
            XCTAssertEqual(
                MinuteSealer.secondsUntilNextMinute(
                    now: Date(timeIntervalSince1970: 179.75)
                ),
                1.25,
                accuracy: 0.001
            )
            XCTAssertEqual(
                MinuteSealer.secondsUntilNextMinute(
                    now: Date(timeIntervalSince1970: -0.25)
                ),
                1.25,
                accuracy: 0.001
            )
        }

        func testMinuteSealerCatchesUpImmediatelyAfterSlowWork() {
            XCTAssertEqual(
                MinuteSealer.nextWakeDelay(
                    now: Date(timeIntervalSince1970: 182),
                    currentMinuteStart: Date(timeIntervalSince1970: 120)
                ),
                0.01,
                accuracy: 0.001
            )
            XCTAssertEqual(
                MinuteSealer.nextWakeDelay(
                    now: Date(timeIntervalSince1970: 181),
                    currentMinuteStart: Date(timeIntervalSince1970: 180)
                ),
                60,
                accuracy: 0.001
            )
        }

        func testDailyMaintenanceGateRunsOncePerLocalDay() {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var gate = DailyMaintenanceGate(calendar: calendar)
            let day = Date(timeIntervalSince1970: 1_800_000_000)

            XCTAssertTrue(gate.admit(now: day))
            XCTAssertFalse(gate.admit(now: day.addingTimeInterval(60 * 60 * 12)))
            XCTAssertTrue(gate.admit(now: day.addingTimeInterval(60 * 60 * 24)))
            XCTAssertFalse(gate.admit(now: day.addingTimeInterval((60 * 60 * 24) + 30)))
        }

        func testDashboardRefreshSchedulerHasNoWakeupsWhileHidden() {
            let virtual = VirtualDashboardTimerScheduler()
            let scheduler = DashboardRefreshScheduler(schedule: virtual.schedule)
            var runtimeRefreshes = 0
            var dataRefreshes = 0

            XCTAssertEqual(scheduler.activeTaskCount, 0)
            virtual.advance(by: 300)
            XCTAssertEqual(runtimeRefreshes, 0)
            XCTAssertEqual(dataRefreshes, 0)

            scheduler.activate(
                isToday: true,
                refreshRuntime: { runtimeRefreshes += 1 },
                refreshData: { dataRefreshes += 1 }
            )
            XCTAssertEqual(scheduler.activeTaskCount, 2)
            XCTAssertEqual(virtual.activeIntervals, [5, 60])
            virtual.advance(by: 60)
            XCTAssertEqual(runtimeRefreshes, 12)
            XCTAssertEqual(dataRefreshes, 1)

            scheduler.deactivate()
            XCTAssertEqual(scheduler.activeTaskCount, 0)
            XCTAssertTrue(virtual.activeIntervals.isEmpty)
            virtual.advance(by: 300)
            XCTAssertEqual(runtimeRefreshes, 12)
            XCTAssertEqual(dataRefreshes, 1)
        }

        func testDashboardRefreshSchedulerSkipsHistoricalDataWakeups() {
            let virtual = VirtualDashboardTimerScheduler()
            let scheduler = DashboardRefreshScheduler(schedule: virtual.schedule)
            var runtimeRefreshes = 0
            var dataRefreshes = 0

            scheduler.activate(
                isToday: false,
                refreshRuntime: { runtimeRefreshes += 1 },
                refreshData: { dataRefreshes += 1 }
            )

            XCTAssertEqual(scheduler.activeTaskCount, 1)
            XCTAssertEqual(virtual.activeIntervals, [5])
            virtual.advance(by: 60)
            XCTAssertEqual(runtimeRefreshes, 12)
            XCTAssertEqual(dataRefreshes, 0)
            XCTAssertGreaterThanOrEqual(DashboardRefreshScheduler.todayDataInterval, 60)
        }

        func testDashboardVisibilityCoordinatorStopsAndResumesOnlyOnRealVisibility() {
            var changes: [Bool] = []
            let coordinator = DashboardVisibilityCoordinator {
                changes.append($0)
            }
            var state = DashboardVisibilityState(
                windowIsVisible: true,
                windowIsMiniaturized: false,
                applicationIsHidden: false,
                windowIsOccluded: false
            )

            coordinator.update(state)
            coordinator.update(state)
            state.windowIsMiniaturized = true
            coordinator.update(state)
            coordinator.update(state)
            state.windowIsMiniaturized = false
            coordinator.update(state)
            state.applicationIsHidden = true
            coordinator.update(state)
            state.applicationIsHidden = false
            coordinator.update(state)
            state.windowIsOccluded = true
            coordinator.update(state)
            state.windowIsOccluded = false
            coordinator.update(state)
            state.windowIsVisible = false
            coordinator.update(state)

            XCTAssertEqual(changes, [true, false, true, false, true, false, true, false])
            XCTAssertFalse(coordinator.permitsRefresh)
        }

        func testDashboardWindowLifecycleOwnsRefreshScheduler() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let viewModel = try String(
                contentsOf:
                    repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/DashboardViewModel.swift"),
                encoding: .utf8
            )
            let windowController = try String(
                contentsOf:
                    repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/DashboardWindowController.swift"),
                encoding: .utf8
            )

            let initializer = try XCTUnwrap(
                viewModel.slice(from: "        init(\n", through: "        deinit {")
            )
            let hidden = try XCTUnwrap(
                viewModel.slice(
                    from: "        func dashboardDidBecomeHidden()",
                    through: "        func togglePause()"
                )
            )
            let close = try XCTUnwrap(
                windowController.slice(
                    from: "        func windowWillClose(",
                    through: "    }\n#endif"
                )
            )

            XCTAssertFalse(initializer.contains("refreshData("))
            XCTAssertFalse(initializer.contains("refreshScheduler.activate("))
            XCTAssertTrue(windowController.contains("viewModel.dashboardDidBecomeVisible()"))
            XCTAssertTrue(close.contains("visibilityCoordinator.update(.hidden)"))
            XCTAssertTrue(close.contains("closingWindow?.contentViewController = nil"))
            XCTAssertTrue(close.contains("self.window = nil"))
            XCTAssertTrue(close.contains("malloc_zone_pressure_relief(nil, 0)"))
            XCTAssertTrue(windowController.contains("windowDidMiniaturize"))
            XCTAssertTrue(windowController.contains("windowDidDeminiaturize"))
            XCTAssertTrue(windowController.contains("windowDidChangeOcclusionState"))
            XCTAssertTrue(windowController.contains("NSApplication.didHideNotification"))
            XCTAssertTrue(windowController.contains("NSApplication.didUnhideNotification"))
            XCTAssertTrue(hidden.contains("refreshScheduler.deactivate()"))
            XCTAssertTrue(hidden.contains("snapshot = .empty(day: selectedDay)"))
        }

        func testComputerHistoryTimelineBuildsRowsLazilyAndIndexesSourcesOnce() throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let page = try String(
                contentsOf:
                    repositoryRoot
                    .appendingPathComponent("Sources/LocalHistoryApp/ComputerHistoryPage.swift"),
                encoding: .utf8
            )
            let timeline = try XCTUnwrap(
                page.slice(
                    from: "        private func episodes(",
                    through: "        private func sources("
                )
            )

            XCTAssertTrue(page.contains("ScrollView {\n                LazyVStack"))
            XCTAssertTrue(timeline.contains("LazyVStack(alignment: .leading"))
            XCTAssertEqual(
                timeline.components(
                    separatedBy: "uniqueKeysWithValues: memory.resources.map"
                ).count - 1,
                1
            )
        }
    }

    private final class VirtualDashboardTimerScheduler {
        private final class Task: DashboardScheduledTask {
            let interval: TimeInterval
            let action: () -> Void
            var nextFire: TimeInterval
            var isCancelled = false

            init(interval: TimeInterval, startingAt start: TimeInterval, action: @escaping () -> Void) {
                self.interval = interval
                self.action = action
                nextFire = start + interval
            }

            func cancel() {
                isCancelled = true
            }
        }

        private var now: TimeInterval = 0
        private var tasks: [Task] = []

        lazy var schedule: DashboardRefreshScheduler.Schedule = { [weak self] interval, action in
            let task = Task(interval: interval, startingAt: self?.now ?? 0, action: action)
            self?.tasks.append(task)
            return task
        }

        var activeIntervals: [TimeInterval] {
            tasks.filter { !$0.isCancelled }.map(\.interval).sorted()
        }

        func advance(by interval: TimeInterval) {
            let target = now + interval
            while let next =
                tasks
                .filter({ !$0.isCancelled && $0.nextFire <= target })
                .min(by: { $0.nextFire < $1.nextFire })
            {
                now = next.nextFire
                next.action()
                next.nextFire += next.interval
            }
            now = target
        }
    }

    extension String {
        fileprivate func slice(from start: String, through end: String) -> String? {
            guard let startRange = range(of: start),
                let endRange = range(of: end, range: startRange.upperBound..<endIndex)
            else { return nil }
            return String(self[startRange.lowerBound..<endRange.lowerBound])
        }
    }
#endif
