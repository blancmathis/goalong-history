#if os(macOS)
    import AppKit
    import Carbon
    import CoreGraphics
    import Foundation
    import LocalHistoryCore

    private let localHistoryEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let monitor = Unmanaged<EventTapMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        autoreleasepool {
            monitor.handle(type: type, event: event)
        }
        return Unmanaged.passUnretained(event)
    }

    /// Immutable, bounded input copied from the `CGEvent` callback. The callback must
    /// never retain a `CGEvent` or call Accessibility/AppKit/storage code because any
    /// of those operations can exceed macOS' event-tap deadline.
    struct EventTapPendingInput: Equatable {
        enum Kind: Equatable {
            case leftMouseDown
            case rightMouseDown
            case otherMouseDown
            case scrollWheel
            case keyDown
            case leftMouseDragged
            case rightMouseDragged
            case otherMouseDragged
            case leftMouseUp
            case rightMouseUp
            case otherMouseUp
            case tapDisabled
        }

        var sequence: UInt64 = 0
        let kind: Kind
        let observedAt: Date
        var lastObservedAt: Date
        var occurrences: Int
        var flagsRawValue: UInt64
        var keyCode: UInt16
        var isRepeat: Bool
        var locationX: Double
        var locationY: Double
        var lastLocationX: Double
        var lastLocationY: Double
        var clickCount: Int
        var scrollDeltaX: Double
        var scrollDeltaY: Double
        var sourceProcessIdentifier: Int64
        var sourceUserIdentifier: Int64
        var sourceStateIdentifier: Int64
        var targetProcessIdentifier: Int64
        let observedContext: ContextSnapshot?
        let capturingWasEnabled: Bool
        let secureInputWasEnabled: Bool

        init(
            kind: Kind,
            observedAt: Date,
            lastObservedAt: Date? = nil,
            occurrences: Int = 1,
            flagsRawValue: UInt64 = 0,
            keyCode: UInt16 = 0,
            isRepeat: Bool = false,
            locationX: Double = 0,
            locationY: Double = 0,
            lastLocationX: Double? = nil,
            lastLocationY: Double? = nil,
            clickCount: Int = 1,
            scrollDeltaX: Double = 0,
            scrollDeltaY: Double = 0,
            sourceProcessIdentifier: Int64 = 0,
            sourceUserIdentifier: Int64 = 0,
            sourceStateIdentifier: Int64 = 0,
            targetProcessIdentifier: Int64 = 0,
            observedContext: ContextSnapshot? = nil,
            capturingWasEnabled: Bool = true,
            secureInputWasEnabled: Bool = false
        ) {
            self.kind = kind
            self.observedAt = observedAt
            self.lastObservedAt = lastObservedAt ?? observedAt
            self.occurrences = max(1, occurrences)
            self.flagsRawValue = flagsRawValue
            self.keyCode = keyCode
            self.isRepeat = isRepeat
            self.locationX = Self.boundedCoordinate(locationX)
            self.locationY = Self.boundedCoordinate(locationY)
            self.lastLocationX = Self.boundedCoordinate(lastLocationX ?? locationX)
            self.lastLocationY = Self.boundedCoordinate(lastLocationY ?? locationY)
            self.clickCount = max(1, clickCount)
            self.scrollDeltaX = scrollDeltaX
            self.scrollDeltaY = scrollDeltaY
            self.sourceProcessIdentifier = sourceProcessIdentifier
            self.sourceUserIdentifier = sourceUserIdentifier
            self.sourceStateIdentifier = sourceStateIdentifier
            self.targetProcessIdentifier = targetProcessIdentifier
            self.observedContext = observedContext
            self.capturingWasEnabled = capturingWasEnabled
            self.secureInputWasEnabled = secureInputWasEnabled
        }

        fileprivate var isCoalescibleTyping: Bool {
            guard kind == .keyDown else { return false }
            let flags = CGEventFlags(rawValue: flagsRawValue)
            return !flags.contains(.maskCommand)
                && !flags.contains(.maskControl)
                && KeyDescriptor.specialName(for: keyCode) == nil
        }

        var eventTimeContextIsPrivate: Bool {
            guard let observedContext else { return false }
            return observedContext.suppressionReason != nil
                || observedContext.focusedElement?.isSecure == true
        }

        func targetIsRepresented(frontmostProcessIdentifier: pid_t?) -> Bool {
            guard targetProcessIdentifier > 0,
                targetProcessIdentifier <= Int64(Int32.max)
            else { return true }
            let target = pid_t(targetProcessIdentifier)
            return frontmostProcessIdentifier == target
        }

        fileprivate mutating func mergeIfAdjacent(with incoming: EventTapPendingInput) -> Bool {
            guard capturingWasEnabled == incoming.capturingWasEnabled,
                secureInputWasEnabled == incoming.secureInputWasEnabled,
                targetProcessIdentifier == incoming.targetProcessIdentifier,
                sourceProcessIdentifier == incoming.sourceProcessIdentifier,
                sourceUserIdentifier == incoming.sourceUserIdentifier,
                sourceStateIdentifier == incoming.sourceStateIdentifier,
                observedContext == incoming.observedContext
            else { return false }

            let gap = incoming.observedAt.timeIntervalSince(lastObservedAt)
            guard gap >= 0 else { return false }
            switch (kind, incoming.kind) {
            case (.scrollWheel, .scrollWheel)
            where gap <= 0.35
                && incoming.lastObservedAt.timeIntervalSince(observedAt) <= 0.70:
                scrollDeltaX += incoming.scrollDeltaX
                scrollDeltaY += incoming.scrollDeltaY
                occurrences += incoming.occurrences
            case (.keyDown, .keyDown)
            where gap <= 1.1
                && incoming.lastObservedAt.timeIntervalSince(observedAt) <= 0.70
                && isCoalescibleTyping && incoming.isCoalescibleTyping:
                occurrences += incoming.occurrences
                isRepeat = isRepeat || incoming.isRepeat
            case (.leftMouseDragged, .leftMouseDragged),
                (.rightMouseDragged, .rightMouseDragged),
                (.otherMouseDragged, .otherMouseDragged)
            where gap <= 0.10
                && incoming.lastObservedAt.timeIntervalSince(observedAt) <= 0.70:
                lastLocationX = incoming.lastLocationX
                lastLocationY = incoming.lastLocationY
                occurrences += incoming.occurrences
            default:
                return false
            }
            lastObservedAt = incoming.lastObservedAt
            return true
        }

        static func boundedCoordinate(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return min(1_000_000, max(-1_000_000, value))
        }
    }

    struct EventTapIngressMetrics: Equatable {
        let capacity: Int
        let payloadCapacityBytes: Int
        let currentDepth: Int
        let maximumDepth: Int
        let acceptedCount: Int
        let coalescedCount: Int
        let droppedCount: Int
        let longestCriticalSectionNanoseconds: UInt64
        let longestCallbackIngressNanoseconds: UInt64
    }

    struct EventTapIngressDropReport: Equatable {
        let count: Int
        let firstObservedAt: Date
        let lastObservedAt: Date
    }

    struct EventTapObservationGap: Equatable {
        let count: Int
        let firstObservedAt: Date
        let lastObservedAt: Date
        let reasons: [String]
    }

    struct EventTapObservationGapAccumulator {
        private static let maximumCount = 1_000_000_000
        private var count = 0
        private var firstObservedAt: Date?
        private var lastObservedAt: Date?
        private var reasons: Set<String> = []

        mutating func record(
            count incomingCount: Int,
            firstObservedAt incomingFirst: Date,
            lastObservedAt incomingLast: Date,
            reason: String
        ) {
            let boundedCount = min(Self.maximumCount, max(1, incomingCount))
            count = min(Self.maximumCount, count + boundedCount)
            firstObservedAt = min(firstObservedAt ?? incomingFirst, incomingFirst)
            lastObservedAt = max(lastObservedAt ?? incomingLast, incomingLast)
            if reasons.count < 8 { reasons.insert(String(reason.prefix(64))) }
        }

        mutating func take() -> EventTapObservationGap? {
            guard count > 0,
                let firstObservedAt,
                let lastObservedAt
            else { return nil }
            let gap = EventTapObservationGap(
                count: count,
                firstObservedAt: firstObservedAt,
                lastObservedAt: lastObservedAt,
                reasons: reasons.sorted()
            )
            self = EventTapObservationGapAccumulator()
            return gap
        }
    }

    /// A small locked FIFO is used instead of dispatching one block per raw input.
    /// Adjacent typing and scroll callbacks are losslessly coalesced. Discrete clicks,
    /// shortcuts and navigation keys retain their position and interaction identity.
    final class EventTapIngressBuffer {
        private let capacity: Int
        private let lock = NSLock()
        private var pending: [EventTapPendingInput?]
        private var head = 0
        private var pendingCount = 0
        private var nextSequence: UInt64 = 1
        private var drainScheduled = false
        private var maximumDepth = 0
        private var acceptedCount = 0
        private var coalescedCount = 0
        private var droppedCount = 0
        private var unreportedDroppedCount = 0
        private var firstUnreportedDropAt: Date?
        private var lastUnreportedDropAt: Date?
        private var longestCriticalSectionNanoseconds: UInt64 = 0
        private var longestCallbackIngressNanoseconds: UInt64 = 0

        init(capacity: Int = 256) {
            let boundedCapacity = max(1, capacity)
            self.capacity = boundedCapacity
            pending = Array(repeating: nil, count: boundedCapacity)
        }

        /// Returns true exactly when the caller must schedule a drain. This method
        /// never performs the drain and never waits for AX, AppKit, or persistence.
        @discardableResult
        func enqueue(
            _ value: EventTapPendingInput,
            callbackStartedAtNanoseconds: UInt64? = nil
        ) -> Bool {
            let started = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            defer {
                let finished = DispatchTime.now().uptimeNanoseconds
                let elapsed = finished &- started
                longestCriticalSectionNanoseconds = max(longestCriticalSectionNanoseconds, elapsed)
                if let callbackStartedAtNanoseconds {
                    longestCallbackIngressNanoseconds = max(
                        longestCallbackIngressNanoseconds,
                        finished &- callbackStartedAtNanoseconds
                    )
                }
                lock.unlock()
            }

            var value = value
            value.sequence = nextSequence
            nextSequence &+= 1

            if pendingCount > 0 {
                let lastIndex = (head + pendingCount - 1) % capacity
                if pending[lastIndex]?.mergeIfAdjacent(with: value) == true {
                    acceptedCount += value.occurrences
                    coalescedCount += value.occurrences
                    return false
                }
            }

            guard pendingCount < capacity else {
                recordDrop(value)
                return false
            }

            let tail = (head + pendingCount) % capacity
            pending[tail] = value
            pendingCount += 1
            acceptedCount += value.occurrences
            maximumDepth = max(maximumDepth, pendingCount)
            guard !drainScheduled else { return false }
            drainScheduled = true
            return true
        }

        func popFirst() -> EventTapPendingInput? {
            lock.lock()
            defer { lock.unlock() }
            guard pendingCount > 0 else {
                drainScheduled = false
                return nil
            }
            let value = pending[head]
            pending[head] = nil
            head = (head + 1) % capacity
            pendingCount -= 1
            return value
        }

        /// Completes one main-thread drain pass without racing a producer. A true
        /// result means the existing scheduling token stays owned by the consumer.
        func finishDrainPass() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard pendingCount == 0 else { return true }
            drainScheduled = false
            return false
        }

        @discardableResult
        func discardPending() -> Int {
            lock.lock()
            defer { lock.unlock() }
            var discarded = 0
            while pendingCount > 0 {
                if let value = pending[head] {
                    discarded += value.occurrences
                    recordDrop(value)
                }
                pending[head] = nil
                head = (head + 1) % capacity
                pendingCount -= 1
            }
            drainScheduled = false
            return discarded
        }

        func takeDropReport() -> EventTapIngressDropReport? {
            lock.lock()
            defer { lock.unlock() }
            guard unreportedDroppedCount > 0,
                let firstUnreportedDropAt,
                let lastUnreportedDropAt
            else { return nil }
            let report = EventTapIngressDropReport(
                count: unreportedDroppedCount,
                firstObservedAt: firstUnreportedDropAt,
                lastObservedAt: lastUnreportedDropAt
            )
            unreportedDroppedCount = 0
            self.firstUnreportedDropAt = nil
            self.lastUnreportedDropAt = nil
            return report
        }

        var metrics: EventTapIngressMetrics {
            lock.lock()
            defer { lock.unlock() }
            return EventTapIngressMetrics(
                capacity: capacity,
                payloadCapacityBytes: capacity * MemoryLayout<EventTapPendingInput?>.stride,
                currentDepth: pendingCount,
                maximumDepth: maximumDepth,
                acceptedCount: acceptedCount,
                coalescedCount: coalescedCount,
                droppedCount: droppedCount,
                longestCriticalSectionNanoseconds: longestCriticalSectionNanoseconds,
                longestCallbackIngressNanoseconds: longestCallbackIngressNanoseconds
            )
        }

        private func recordDrop(_ value: EventTapPendingInput) {
            droppedCount += value.occurrences
            unreportedDroppedCount += value.occurrences
            firstUnreportedDropAt = min(firstUnreportedDropAt ?? value.observedAt, value.observedAt)
            lastUnreportedDropAt = max(lastUnreportedDropAt ?? value.lastObservedAt, value.lastObservedAt)
        }
    }

    final class EventTapThreadGate {
        private let lock = NSLock()
        private var cancelled = false
        private var enabled = false
        private var runLoop: CFRunLoop?

        func install(runLoop: CFRunLoop) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled, self.runLoop == nil else { return false }
            self.runLoop = runLoop
            return true
        }

        func markEnabled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled, runLoop != nil else { return false }
            enabled = true
            return true
        }

        var isEnabled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return enabled && !cancelled
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            enabled = false
            let installedRunLoop = runLoop
            lock.unlock()
            if let installedRunLoop {
                CFRunLoopStop(installedRunLoop)
                CFRunLoopWakeUp(installedRunLoop)
            }
        }

        func clear() {
            lock.lock()
            runLoop = nil
            enabled = false
            lock.unlock()
        }
    }

    protocol EventTapRestartScheduledTask: AnyObject {
        func cancel()
    }

    private final class EventTapRestartDispatchTask: EventTapRestartScheduledTask {
        private let workItem: DispatchWorkItem

        init(workItem: DispatchWorkItem) {
            self.workItem = workItem
        }

        func cancel() {
            workItem.cancel()
        }
    }

    /// Owns the single unexpected-restart wakeup. The token check is intentional:
    /// cancelling a DispatchWorkItem does not guarantee that an already submitted
    /// closure will never be invoked.
    final class EventTapRestartGate {
        typealias Schedule = (
            TimeInterval,
            @escaping () -> Void
        ) -> EventTapRestartScheduledTask

        private let scheduleTask: Schedule
        private var pendingToken: UUID?
        private var pendingTask: EventTapRestartScheduledTask?

        init(schedule: @escaping Schedule) {
            scheduleTask = schedule
        }

        convenience init() {
            self.init { delay, action in
                let workItem = DispatchWorkItem(block: action)
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + max(0, delay),
                    execute: workItem
                )
                return EventTapRestartDispatchTask(workItem: workItem)
            }
        }

        var isScheduled: Bool {
            pendingToken != nil
        }

        @discardableResult
        func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> Bool {
            guard pendingToken == nil else { return false }
            let token = UUID()
            pendingToken = token
            let task = scheduleTask(max(0, delay)) { [weak self] in
                guard let self, self.pendingToken == token else { return }
                self.pendingToken = nil
                self.pendingTask = nil
                action()
            }
            if pendingToken == token {
                pendingTask = task
            } else {
                task.cancel()
            }
            return true
        }

        func cancel() {
            pendingToken = nil
            pendingTask?.cancel()
            pendingTask = nil
        }
    }

    final class EventTapMonitor {
        private let recorder: EventRecorder
        private let contextMonitor: ContextMonitor
        private let contextProvider: ContextProvider
        private let state: CaptureState
        private let configManager: ConfigManager
        private let captureHealth: CaptureHealthStore
        private let ingress = EventTapIngressBuffer(capacity: 256)
        private let eventTapLock = NSLock()

        private var eventTap: CFMachPort?
        private var runLoopSource: CFRunLoopSource?
        private var eventTapThread: Thread?
        private var eventTapStoppedSignal: DispatchSemaphore?
        private var eventTapThreadGate: EventTapThreadGate?
        private let unexpectedRestartGate: EventTapRestartGate
        private var consecutiveUnexpectedRestartAttempts = 0
        private var lastSuccessfulStartAt: Date?
        private(set) var isRunning = false
        var hasPendingUnexpectedRestart: Bool {
            unexpectedRestartGate.isScheduled
        }
        private(set) var staleInputDropCount = 0
        private(set) var privacyInputDropCount = 0
        private(set) var stopDiscardedInputCount = 0
        private var observationGap = EventTapObservationGapAccumulator()
        private var observationGapWorkItem: DispatchWorkItem?
        private var interactionBoundaryGeneration: UInt64 = 0

        static let maximumIngressAge: TimeInterval = 0.75
        static let stableRunDurationBeforeRestartReset: TimeInterval = 60
        static let minimumUnexpectedRestartDelay: TimeInterval = 1
        static let maximumUnexpectedRestartDelay: TimeInterval = 60

        static func ingressAgeIsAcceptable(observedAt: Date, now: Date = Date()) -> Bool {
            let age = now.timeIntervalSince(observedAt)
            return age >= -0.1 && age <= maximumIngressAge
        }

        static func unexpectedRestartDelay(
            consecutiveAttempt: Int,
            jitterUnit: Double
        ) -> TimeInterval {
            let boundedAttempt = min(16, max(1, consecutiveAttempt))
            let exponent = Double(boundedAttempt - 1)
            let uncapped = minimumUnexpectedRestartDelay * pow(2, exponent)
            let base = min(maximumUnexpectedRestartDelay, uncapped)
            let boundedJitter = min(1, max(0, jitterUnit.isFinite ? jitterUnit : 0.5))
            let multiplier = 0.85 + (0.30 * boundedJitter)
            return base * multiplier
        }

        private var secureInputWasActive = false

        private var typingCount = 0
        private var typingStartedAt: Date?
        private var typingLastAt: Date?
        private var typingContext: ContextSnapshot?
        private var typingOrigin: InputOriginSnapshot?
        private var typingInteractionID: String?
        private var typingFirstSequence: UInt64?
        private var typingFlushWorkItem: DispatchWorkItem?

        private var scrollDeltaX = 0.0
        private var scrollDeltaY = 0.0
        private var scrollEventCount = 0
        private var scrollStartedAt: Date?
        private var scrollLastAt: Date?
        private var scrollContext: ContextSnapshot?
        private var scrollOrigin: InputOriginSnapshot?
        private var scrollInteractionID: String?
        private var scrollFirstSequence: UInt64?
        private var scrollFlushWorkItem: DispatchWorkItem?
        private var typingAfterWorkItem: DispatchWorkItem?
        private var scrollAfterWorkItem: DispatchWorkItem?
        private var typingSettledWorkItem: DispatchWorkItem?
        private var scrollSettledWorkItem: DispatchWorkItem?
        private var deferredSemanticCaptures: [UUID: DispatchWorkItem] = [:]
        private var deferredSemanticCaptureOrder: [UUID] = []

        private static let maximumDeferredSemanticCaptures = 64

        private struct PointerDownState {
            let interactionID: String
            let button: String
            let startedAt: Date
            let sequence: UInt64
            let startX: Double
            let startY: Double
            let clickCount: Int
            let nearEventContext: ContextSnapshot
            let target: ElementSnapshot?
            let origin: InputOriginSnapshot
        }

        private struct ActiveDragState {
            let interactionID: String
            let down: PointerDownState
            var lastX: Double
            var lastY: Double
            var eventCount: Int
            var origin: InputOriginSnapshot
        }

        private var pointerDownStates: [String: PointerDownState] = [:]
        private var activeDragStates: [String: ActiveDragState] = [:]

        init(
            recorder: EventRecorder,
            contextMonitor: ContextMonitor,
            contextProvider: ContextProvider,
            state: CaptureState,
            configManager: ConfigManager,
            captureHealth: CaptureHealthStore,
            unexpectedRestartGate: EventTapRestartGate = EventTapRestartGate()
        ) {
            self.recorder = recorder
            self.contextMonitor = contextMonitor
            self.contextProvider = contextProvider
            self.state = state
            self.configManager = configManager
            self.captureHealth = captureHealth
            self.unexpectedRestartGate = unexpectedRestartGate
        }

        @discardableResult
        func start() -> Bool {
            guard !isRunning else { return true }
            // The owned retry is the only tap-creation attempt during backoff.
            // Permission watchdog ticks may still refresh permissions, but cannot
            // collapse the exponential delay into repeated CGEvent.tapCreate calls.
            guard !unexpectedRestartGate.isScheduled else { return false }
            guard eventTapThread == nil else {
                captureHealth.markTapCreationFailed("Previous event-tap thread has not stopped")
                return false
            }

            let eventTypes: [CGEventType] = [
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
                .leftMouseDragged,
                .rightMouseDragged,
                .otherMouseDragged,
                .leftMouseUp,
                .rightMouseUp,
                .otherMouseUp,
                .scrollWheel,
                .keyDown,
            ]
            let mask = eventTypes.reduce(CGEventMask(0)) { partial, type in
                partial | (CGEventMask(1) << type.rawValue)
            }

            guard
                let tap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .tailAppendEventTap,
                    options: .listenOnly,
                    eventsOfInterest: mask,
                    callback: localHistoryEventTapCallback,
                    userInfo: Unmanaged.passUnretained(self).toOpaque()
                )
            else {
                Diagnostics.write("Could not create event tap. Input Monitoring may not be granted yet.")
                captureHealth.markTapCreationFailed("CGEvent.tapCreate returned nil")
                return false
            }

            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                CFMachPortInvalidate(tap)
                Diagnostics.write("Could not create event-tap run-loop source")
                captureHealth.markTapCreationFailed("CFMachPortCreateRunLoopSource returned nil")
                return false
            }

            setEventTap(tap)
            runLoopSource = source

            // Keep the event-tap callback on its own run loop. All AppKit, AX,
            // analysis and persistence work is drained on the main thread from the
            // bounded FIFO below, so a slow accessibility query cannot time out the tap.
            let ready = DispatchSemaphore(value: 0)
            let stopped = DispatchSemaphore(value: 0)
            let gate = EventTapThreadGate()
            let thread = Thread { [weak self] in
                autoreleasepool {
                    defer {
                        let cancelled = gate.isCancelled
                        gate.clear()
                        stopped.signal()
                        DispatchQueue.main.async { [weak self] in
                            self?.eventTapThreadExited(gate: gate, expected: cancelled)
                        }
                    }
                    guard let self else {
                        ready.signal()
                        return
                    }
                    guard let runLoop = CFRunLoopGetCurrent(),
                        gate.install(runLoop: runLoop)
                    else {
                        ready.signal()
                        return
                    }
                    CFRunLoopAddSource(runLoop, source, .commonModes)
                    CGEvent.tapEnable(tap: tap, enable: true)
                    guard gate.markEnabled() else {
                        CFRunLoopRemoveSource(runLoop, source, .commonModes)
                        ready.signal()
                        return
                    }
                    ready.signal()
                    withExtendedLifetime(self) {
                        CFRunLoopRun()
                    }
                    CFRunLoopRemoveSource(runLoop, source, .commonModes)
                }
            }
            thread.name = "ai.goalong.localhistory.event-tap"
            thread.qualityOfService = QualityOfService.userInteractive
            eventTapThread = thread
            eventTapStoppedSignal = stopped
            eventTapThreadGate = gate
            thread.start()
            guard ready.wait(timeout: .now() + 2.0) == .success, gate.isEnabled else {
                gate.cancel()
                invalidateAndClearEventTap()
                let didStop = stopped.wait(timeout: .now() + 1.0) == .success
                if didStop {
                    runLoopSource = nil
                    eventTapThread = nil
                    eventTapStoppedSignal = nil
                    eventTapThreadGate = nil
                }
                Diagnostics.write("Timed out while starting the event-tap run loop")
                captureHealth.markTapCreationFailed("Event-tap run loop did not start")
                return false
            }
            isRunning = true
            lastSuccessfulStartAt = Date()
            unexpectedRestartGate.cancel()
            Diagnostics.write("Event tap created and enabled; waiting for a real input callback")
            captureHealth.markTapEnabled()
            return true
        }

        func stop() {
            unexpectedRestartGate.cancel()
            consecutiveUnexpectedRestartAttempts = 0
            lastSuccessfulStartAt = nil
            eventTapThreadGate?.cancel()
            invalidateAndClearEventTap()
            let didStop =
                eventTapStoppedSignal.map {
                    $0.wait(timeout: .now() + 1.0) == .success
                } ?? true

            drainOnePendingInputForStop()
            isRunning = false
            stopDiscardedInputCount += ingress.discardPending()
            reportIngressDropsIfNeeded(reason: "monitor_stopped")
            flushObservationGap()
            cancelOpenInteractionsForBoundary(discardPendingInput: false)

            if didStop {
                runLoopSource = nil
                eventTapThread = nil
                eventTapStoppedSignal = nil
                eventTapThreadGate = nil
            } else {
                Diagnostics.write(
                    "Event-tap thread did not stop within one second; restart remains blocked"
                )
            }
            captureHealth.markTapDisabled("Event tap stopped")
        }

        func handle(type: CGEventType, event: CGEvent) {
            let callbackStarted = DispatchTime.now().uptimeNanoseconds
            let kind: EventTapPendingInput.Kind
            switch type {
            case .leftMouseDown: kind = .leftMouseDown
            case .rightMouseDown: kind = .rightMouseDown
            case .otherMouseDown: kind = .otherMouseDown
            case .leftMouseDragged: kind = .leftMouseDragged
            case .rightMouseDragged: kind = .rightMouseDragged
            case .otherMouseDragged: kind = .otherMouseDragged
            case .leftMouseUp: kind = .leftMouseUp
            case .rightMouseUp: kind = .rightMouseUp
            case .otherMouseUp: kind = .otherMouseUp
            case .scrollWheel: kind = .scrollWheel
            case .keyDown: kind = .keyDown
            case .tapDisabledByTimeout, .tapDisabledByUserInput: kind = .tapDisabled
            default: return
            }

            // Only scalar fields are copied here. In particular, resolving the source
            // process name with NSRunningApplication is deferred to the main-thread drain.
            let observedAt = Date()
            let input = EventTapPendingInput(
                kind: kind,
                observedAt: observedAt,
                flagsRawValue: event.flags.rawValue,
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                locationX: Double(event.location.x),
                locationY: Double(event.location.y),
                clickCount: max(1, Int(event.getIntegerValueField(.mouseEventClickState))),
                scrollDeltaX: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
                scrollDeltaY: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
                sourceProcessIdentifier: event.getIntegerValueField(.eventSourceUnixProcessID),
                sourceUserIdentifier: event.getIntegerValueField(.eventSourceUserID),
                sourceStateIdentifier: event.getIntegerValueField(.eventSourceStateID),
                targetProcessIdentifier: event.getIntegerValueField(.eventTargetUnixProcessID),
                observedContext: contextMonitor.latestSnapshot,
                capturingWasEnabled: state.isCapturing,
                secureInputWasEnabled: IsSecureEventInputEnabled()
            )

            // Re-enable the tap synchronously, but defer health persistence and logs.
            // `CGEvent.tapEnable` does not touch AX, AppKit, or local storage.
            if kind == .tapDisabled {
                reenableEventTap()
            }

            let shouldScheduleDrain = ingress.enqueue(
                input,
                callbackStartedAtNanoseconds: callbackStarted
            )
            if shouldScheduleDrain {
                DispatchQueue.main.async { [weak self] in
                    self?.drainPendingEvents()
                }
            }
        }

        var ingressMetrics: EventTapIngressMetrics {
            ingress.metrics
        }

        private func setEventTap(_ tap: CFMachPort?) {
            eventTapLock.lock()
            eventTap = tap
            eventTapLock.unlock()
        }

        private func invalidateAndClearEventTap() {
            eventTapLock.lock()
            let tap = eventTap
            eventTap = nil
            eventTapLock.unlock()
            if let tap { CFMachPortInvalidate(tap) }
        }

        private func reenableEventTap() {
            eventTapLock.lock()
            let tap = eventTap
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            eventTapLock.unlock()
        }

        private func eventTapThreadExited(gate: EventTapThreadGate, expected: Bool) {
            guard eventTapThreadGate === gate else { return }
            let shouldRestart = isRunning && !expected
            let priorRunDuration = lastSuccessfulStartAt.map { Date().timeIntervalSince($0) } ?? 0
            lastSuccessfulStartAt = nil
            invalidateAndClearEventTap()
            runLoopSource = nil
            eventTapThread = nil
            eventTapStoppedSignal = nil
            eventTapThreadGate = nil
            guard shouldRestart else { return }

            isRunning = false
            captureHealth.markTapDisabled("Event-tap run loop exited unexpectedly")
            if priorRunDuration >= Self.stableRunDurationBeforeRestartReset {
                consecutiveUnexpectedRestartAttempts = 0
            }
            consecutiveUnexpectedRestartAttempts = min(
                16,
                consecutiveUnexpectedRestartAttempts + 1
            )
            scheduleUnexpectedRestart()
        }

        private func scheduleUnexpectedRestart() {
            guard !unexpectedRestartGate.isScheduled else { return }
            let delay = Self.unexpectedRestartDelay(
                consecutiveAttempt: consecutiveUnexpectedRestartAttempts,
                jitterUnit: Double.random(in: 0...1)
            )
            let didSchedule = unexpectedRestartGate.schedule(after: delay) { [weak self] in
                guard let self else { return }
                guard !self.isRunning, self.eventTapThread == nil else { return }
                if !self.start() {
                    self.consecutiveUnexpectedRestartAttempts = min(
                        16,
                        self.consecutiveUnexpectedRestartAttempts + 1
                    )
                    self.scheduleUnexpectedRestart()
                }
            }
            guard didSchedule else { return }
            Diagnostics.write(
                "Event-tap run loop exited unexpectedly; retrying in "
                    + String(format: "%.2f", delay) + " seconds"
            )
        }

        private func drainPendingEvents() {
            dispatchPrecondition(condition: .onQueue(.main))
            guard let input = ingress.popFirst() else {
                reportIngressDropsIfNeeded()
                return
            }
            process(input)
            reportIngressDropsIfNeeded()

            // Yield between logical inputs. This lets due after/settled captures run
            // between discrete actions instead of waiting behind an AX-heavy backlog.
            if ingress.finishDrainPass() {
                DispatchQueue.main.async { [weak self] in
                    self?.drainPendingEvents()
                }
            }
        }

        private func drainOnePendingInputForStop() {
            dispatchPrecondition(condition: .onQueue(.main))
            if let input = ingress.popFirst() {
                process(input)
            }
            reportIngressDropsIfNeeded()
        }

        private func reportIngressDropsIfNeeded(reason: String = "bounded_ingress_overflow") {
            guard let report = ingress.takeDropReport() else { return }
            var droppedCount = report.count
            var firstDroppedAt = report.firstObservedAt
            var lastDroppedAt = report.lastObservedAt
            // Missing callbacks make it impossible to prove that an open burst or
            // pointer gesture stayed on the public side of a privacy boundary.
            cancelOpenInteractionsForBoundary(discardPendingInput: true)
            if let boundaryDiscard = ingress.takeDropReport() {
                let sum = droppedCount.addingReportingOverflow(boundaryDiscard.count)
                droppedCount = sum.overflow ? Int.max : sum.partialValue
                firstDroppedAt = min(firstDroppedAt, boundaryDiscard.firstObservedAt)
                lastDroppedAt = max(lastDroppedAt, boundaryDiscard.lastObservedAt)
            }
            Diagnostics.write(
                "Event-tap ingress lost \(droppedCount) raw callback(s): \(reason)"
            )
            noteObservationGap(
                count: droppedCount,
                firstObservedAt: firstDroppedAt,
                lastObservedAt: lastDroppedAt,
                reason: reason
            )
        }

        /// Collapses a burst of callback losses into one bounded, durable continuity
        /// marker. The raw callback payload is never retained; only the count, time
        /// bounds and a small reason set are persisted.
        private func noteObservationGap(
            count: Int,
            firstObservedAt: Date,
            lastObservedAt: Date,
            reason: String
        ) {
            observationGap.record(
                count: count,
                firstObservedAt: firstObservedAt,
                lastObservedAt: lastObservedAt,
                reason: reason
            )
            observationGapWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.flushObservationGap()
            }
            observationGapWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }

        private func flushObservationGap() {
            observationGapWorkItem?.cancel()
            observationGapWorkItem = nil
            guard let gap = observationGap.take() else { return }

            recorder.record(
                kind: .recorderHealth,
                message: "Input observation gap",
                metadata: [
                    "observation_gap": "true",
                    "dropped_input_callbacks": String(gap.count),
                    "gap_first_unix_ms": String(
                        Int64(gap.firstObservedAt.timeIntervalSince1970 * 1_000)
                    ),
                    "gap_last_unix_ms": String(
                        Int64(gap.lastObservedAt.timeIntervalSince1970 * 1_000)
                    ),
                    "gap_reasons": gap.reasons.joined(separator: ","),
                ],
                timestamp: gap.lastObservedAt
            )
        }

        private func process(_ input: EventTapPendingInput) {
            guard isRunning else { return }
            if input.kind == .tapDisabled {
                cancelOpenInteractionsForBoundary()
                captureHealth.markTapControlCallback()
                captureHealth.markTapDisabled("macOS disabled the event tap")
                captureHealth.markTapEnabled()
                Diagnostics.write("Event tap was disabled and has been re-enabled")
                return
            }

            guard input.capturingWasEnabled, state.isCapturing else {
                cancelOpenInteractionsForBoundary()
                return
            }
            guard Self.ingressAgeIsAcceptable(observedAt: input.lastObservedAt) else {
                staleInputDropCount += input.occurrences
                noteObservationGap(
                    count: input.occurrences,
                    firstObservedAt: input.observedAt,
                    lastObservedAt: input.lastObservedAt,
                    reason: "stale_ingress"
                )
                cancelOpenInteractionsForBoundary()
                return
            }
            if input.secureInputWasEnabled || IsSecureEventInputEnabled() {
                let freshSecureContext = contextMonitor.sampleNow()
                suppressForSecureInput(using: freshSecureContext)
                return
            }
            if input.eventTimeContextIsPrivate, let observedContext = input.observedContext {
                privacyInputDropCount += input.occurrences
                if observedContext.suppressionReason == .secureInput
                    || observedContext.focusedElement?.isSecure == true
                {
                    suppressForSecureInput(using: observedContext)
                } else {
                    cancelOpenInteractionsForBoundary()
                    _ = contextMonitor.sampleNow()
                }
                return
            }

            // Every drained logical input gets one fresh privacy/context probe. Typing
            // and scroll callbacks may be coalesced before this point, but neither they
            // nor pointer gestures may reuse the last known-safe snapshot. This work is
            // deliberately off the event-tap callback thread.
            let frontmostPID = contextProvider.frontmostProcessIdentifier()
            guard input.targetIsRepresented(frontmostProcessIdentifier: frontmostPID) else {
                privacyInputDropCount += input.occurrences
                cancelOpenInteractionsForBoundary()
                return
            }
            guard let context = contextMonitor.sampleNow() else {
                noteObservationGap(
                    count: input.occurrences,
                    firstObservedAt: input.observedAt,
                    lastObservedAt: input.lastObservedAt,
                    reason: "context_unavailable"
                )
                cancelOpenInteractionsForBoundary()
                return
            }
            if let suppressionReason = context.suppressionReason {
                privacyInputDropCount += input.occurrences
                if suppressionReason == .secureInput {
                    suppressForSecureInput(using: context)
                } else {
                    cancelOpenInteractionsForBoundary()
                }
                return
            }
            if context.focusedElement?.isSecure == true {
                suppressForSecureInput(using: context)
                return
            }
            guard Self.ingressAgeIsAcceptable(observedAt: input.lastObservedAt) else {
                staleInputDropCount += input.occurrences
                noteObservationGap(
                    count: input.occurrences,
                    firstObservedAt: input.observedAt,
                    lastObservedAt: input.lastObservedAt,
                    reason: "stale_after_context_sample"
                )
                cancelOpenInteractionsForBoundary()
                return
            }
            resumeAfterSecureInputIfNeeded(using: context)
            // `observedContext` is only a callback-time rejection signal above. It is
            // never reused as interaction evidence after a fresh probe succeeds.
            let nearEventContext = context
            // A callback only proves healthy capture after it crosses the event-time
            // privacy, target and freshness gates above.
            captureHealth.markInputCallback(at: input.lastObservedAt)

            switch input.kind {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                handleMouseDown(input: input, context: context, nearEventContext: nearEventContext)
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                handleMouseDragged(input: input, context: context, nearEventContext: nearEventContext)
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                handleMouseUp(input: input, context: context)
            case .scrollWheel:
                handleScroll(input: input, context: context, nearEventContext: nearEventContext)
            case .keyDown:
                handleKeyDown(input: input, context: context, nearEventContext: nearEventContext)
            default:
                break
            }
        }

        private func suppressForSecureInput(using context: ContextSnapshot?) {
            cancelOpenInteractionsForBoundary()
            captureHealth.setSuppression(.secureInput)
            guard !secureInputWasActive else { return }
            secureInputWasActive = true
            let safeContext = context.map {
                ContextSnapshot(
                    app: $0.app,
                    window: nil,
                    focusedElement: nil,
                    url: nil,
                    suppressionReason: .secureInput
                )
            }
            recorder.record(
                kind: .secureInputSuppressed,
                context: safeContext,
                suppressionReason: .secureInput,
                message: "All input detail suppressed while Secure Input or a secure control is active"
            )
        }

        /// Cancels without persisting. Once privacy, freshness or continuity becomes
        /// uncertain, a burst or gesture cannot be safely split at the boundary.
        private func cancelOpenInteractionsForBoundary(discardPendingInput: Bool = false) {
            interactionBoundaryGeneration &+= 1
            if discardPendingInput {
                _ = ingress.discardPending()
            }
            typingFlushWorkItem?.cancel()
            typingFlushWorkItem = nil
            scrollFlushWorkItem?.cancel()
            scrollFlushWorkItem = nil
            typingAfterWorkItem?.cancel()
            typingAfterWorkItem = nil
            scrollAfterWorkItem?.cancel()
            scrollAfterWorkItem = nil
            typingSettledWorkItem?.cancel()
            typingSettledWorkItem = nil
            scrollSettledWorkItem?.cancel()
            scrollSettledWorkItem = nil
            for capture in deferredSemanticCaptures.values {
                capture.cancel()
            }
            deferredSemanticCaptures.removeAll(keepingCapacity: true)
            deferredSemanticCaptureOrder.removeAll(keepingCapacity: true)
            resetTypingBurst()
            resetScrollBurst()
            pointerDownStates.removeAll(keepingCapacity: true)
            activeDragStates.removeAll(keepingCapacity: true)
        }

        private func resumeAfterSecureInputIfNeeded(using context: ContextSnapshot) {
            guard secureInputWasActive else { return }
            secureInputWasActive = false
            captureHealth.setSuppression(nil)
            recorder.record(
                kind: .secureInputResumed,
                context: context,
                message: "Secure Input and secure-control suppression ended"
            )
        }

        private func handleMouseDown(
            input: EventTapPendingInput,
            context: ContextSnapshot,
            nearEventContext: ContextSnapshot
        ) {
            guard configManager.config.captureClicks else { return }
            flushTypingBurst()
            flushScrollBurst()

            let location = CGPoint(x: input.locationX, y: input.locationY)
            let button = buttonName(for: input.kind)
            let origin = inputOrigin(from: input)
            let interactionID = UUID().uuidString
            let target = contextProvider.element(
                at: location,
                expectedProcessIdentifier: context.app.processIdentifier
            )
            // Classify the gesture only at mouse-up. AX is sampled after the callback
            // leaves the event-tap thread, so this is deliberately `near_event`, not a
            // claim that the application had not yet reacted to the input.
            captureNearEvent(
                interactionID: interactionID,
                trigger: "pointer",
                context: nearEventContext
            )
            activeDragStates.removeValue(forKey: button)
            pointerDownStates[button] = PointerDownState(
                interactionID: interactionID,
                button: button,
                startedAt: input.observedAt,
                sequence: input.sequence,
                startX: input.locationX,
                startY: input.locationY,
                clickCount: input.clickCount,
                nearEventContext: nearEventContext,
                target: target,
                origin: origin
            )
        }

        private func handleMouseDragged(
            input: EventTapPendingInput,
            context: ContextSnapshot,
            nearEventContext: ContextSnapshot
        ) {
            flushTypingBurst()
            flushScrollBurst()
            guard configManager.config.captureClicks else { return }

            let button = buttonName(for: input.kind)
            let origin = inputOrigin(from: input)
            let down =
                pointerDownStates[button]
                ?? PointerDownState(
                    interactionID: UUID().uuidString,
                    button: button,
                    startedAt: input.observedAt,
                    sequence: input.sequence,
                    startX: input.locationX,
                    startY: input.locationY,
                    clickCount: input.clickCount,
                    nearEventContext: nearEventContext,
                    target: nil,
                    origin: origin
                )
            pointerDownStates[button] = down

            var drag: ActiveDragState
            if let existing = activeDragStates[button] {
                drag = existing
            } else {
                drag = ActiveDragState(
                    interactionID: down.interactionID,
                    down: down,
                    lastX: input.lastLocationX,
                    lastY: input.lastLocationY,
                    eventCount: 0,
                    origin: down.origin
                )
            }
            drag.lastX = input.lastLocationX
            drag.lastY = input.lastLocationY
            drag.eventCount += input.occurrences
            drag.origin = mergeOrigin(drag.origin, origin)
            activeDragStates[button] = drag
        }

        private func handleMouseUp(input: EventTapPendingInput, context: ContextSnapshot) {
            flushTypingBurst()
            flushScrollBurst()
            let button = buttonName(for: input.kind)
            defer {
                pointerDownStates.removeValue(forKey: button)
                activeDragStates.removeValue(forKey: button)
            }
            guard configManager.config.captureClicks else { return }

            if var drag = activeDragStates[button] {
                completeDrag(drag: &drag, input: input, context: context, button: button)
                return
            }
            guard let down = pointerDownStates[button] else { return }

            recorder.record(
                kind: .mouseClick,
                context: down.nearEventContext,
                element: down.target,
                pointer: PointerSnapshot(
                    button: button,
                    x: down.startX,
                    y: down.startY,
                    clickCount: down.clickCount
                ),
                inputOrigin: mergeOrigin(down.origin, inputOrigin(from: input)),
                metadata: interactionMetadata(
                    interactionID: down.interactionID,
                    trigger: "click",
                    observedAt: down.startedAt,
                    sequence: down.sequence
                ),
                timestamp: down.startedAt
            )
            captureAfter(
                interactionID: down.interactionID,
                trigger: "click",
                observedAt: input.lastObservedAt
            )
        }

        private func completeDrag(
            drag: inout ActiveDragState,
            input: EventTapPendingInput,
            context: ContextSnapshot,
            button: String
        ) {

            drag.lastX = input.lastLocationX
            drag.lastY = input.lastLocationY
            drag.origin = mergeOrigin(drag.origin, inputOrigin(from: input))
            let endPoint = CGPoint(x: drag.lastX, y: drag.lastY)
            let target = contextProvider.element(
                at: endPoint,
                expectedProcessIdentifier: context.app.processIdentifier
            )
            let distance = min(
                2_000_000,
                hypot(drag.lastX - drag.down.startX, drag.lastY - drag.down.startY)
            )
            var metadata = interactionMetadata(
                interactionID: drag.interactionID,
                trigger: "drag",
                observedAt: drag.down.startedAt,
                sequence: drag.down.sequence
            )
            metadata["pointer_gesture"] = "drag"
            metadata["drag_start_x"] = String(Int(drag.down.startX.rounded()))
            metadata["drag_start_y"] = String(Int(drag.down.startY.rounded()))
            metadata["drag_end_x"] = String(Int(drag.lastX.rounded()))
            metadata["drag_end_y"] = String(Int(drag.lastY.rounded()))
            metadata["drag_distance"] = String(Int(distance.rounded()))
            metadata["drag_event_count"] = String(max(1, drag.eventCount))
            metadata["duration_ms"] = String(
                max(0, Int(input.lastObservedAt.timeIntervalSince(drag.down.startedAt) * 1_000))
            )

            recorder.record(
                kind: .mouseClick,
                context: context,
                element: target,
                pointer: PointerSnapshot(
                    button: button,
                    x: drag.lastX,
                    y: drag.lastY,
                    clickCount: 1
                ),
                inputOrigin: drag.origin,
                message: "Pointer drag completed",
                metadata: metadata,
                timestamp: input.lastObservedAt
            )
            captureAfter(
                interactionID: drag.interactionID,
                trigger: "drag",
                observedAt: input.lastObservedAt
            )
        }

        private func buttonName(for kind: EventTapPendingInput.Kind) -> String {
            switch kind {
            case .leftMouseDown, .leftMouseDragged, .leftMouseUp: return "left"
            case .rightMouseDown, .rightMouseDragged, .rightMouseUp: return "right"
            default: return "other"
            }
        }

        private func handleScroll(
            input: EventTapPendingInput,
            context: ContextSnapshot,
            nearEventContext: ContextSnapshot
        ) {
            flushTypingBurst()
            guard configManager.config.captureScroll else { return }

            if scrollContext?.fingerprint != context.fingerprint {
                flushScrollBurst()
            }
            if scrollEventCount == 0 {
                let interactionID = UUID().uuidString
                scrollInteractionID = interactionID
                scrollFirstSequence = input.sequence
                captureNearEvent(
                    interactionID: interactionID,
                    trigger: "scroll",
                    context: nearEventContext
                )
                scheduleScrollAfter(
                    interactionID: interactionID,
                    observedAt: input.observedAt
                )
            }

            scrollContext = context
            scrollOrigin = mergeOrigin(scrollOrigin, inputOrigin(from: input))
            if scrollStartedAt == nil { scrollStartedAt = input.observedAt }
            scrollLastAt = input.lastObservedAt
            scrollDeltaX += input.scrollDeltaX
            scrollDeltaY += input.scrollDeltaY
            scrollEventCount += input.occurrences
            if let scrollInteractionID {
                rescheduleScrollSettled(
                    interactionID: scrollInteractionID,
                    observedAt: input.lastObservedAt
                )
            }

            scrollFlushWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.flushScrollBurst()
            }
            scrollFlushWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
        }

        private func handleKeyDown(
            input: EventTapPendingInput,
            context: ContextSnapshot,
            nearEventContext: ContextSnapshot
        ) {
            flushScrollBurst()
            let flags = CGEventFlags(rawValue: input.flagsRawValue)
            let modifiers = KeyDescriptor.modifierNames(from: flags)
            let isShortcut = flags.contains(.maskCommand) || flags.contains(.maskControl)

            if isShortcut, configManager.config.captureShortcuts {
                flushTypingBurst()
                let interactionID = UUID().uuidString
                captureNearEvent(
                    interactionID: interactionID,
                    trigger: "shortcut",
                    context: nearEventContext
                )
                let keyboard = KeyboardSnapshot(
                    category: "shortcut",
                    key: KeyDescriptor.name(for: input.keyCode),
                    modifiers: modifiers,
                    isRepeat: input.isRepeat
                )
                recorder.record(
                    kind: .keyboardShortcut,
                    context: context,
                    keyboard: keyboard,
                    inputOrigin: inputOrigin(from: input),
                    metadata: interactionMetadata(
                        interactionID: interactionID,
                        trigger: "shortcut",
                        input: input
                    ),
                    timestamp: input.observedAt
                )
                captureAfter(
                    interactionID: interactionID,
                    trigger: "shortcut",
                    observedAt: input.observedAt
                )
                return
            }
            if isShortcut {
                // A disabled shortcut category must never fall through as text activity.
                flushTypingBurst()
                return
            }

            if let specialKey = KeyDescriptor.specialName(for: input.keyCode) {
                flushTypingBurst()
                guard configManager.config.captureKeyboardActivity else { return }
                let interactionID = UUID().uuidString
                captureNearEvent(
                    interactionID: interactionID,
                    trigger: "navigation_key",
                    context: nearEventContext
                )
                let keyboard = KeyboardSnapshot(
                    category: "navigation",
                    key: specialKey,
                    modifiers: modifiers,
                    isRepeat: input.isRepeat
                )
                recorder.record(
                    kind: .keyPressed,
                    context: context,
                    keyboard: keyboard,
                    inputOrigin: inputOrigin(from: input),
                    metadata: interactionMetadata(
                        interactionID: interactionID,
                        trigger: "navigation_key",
                        input: input
                    ),
                    timestamp: input.observedAt
                )
                captureAfter(
                    interactionID: interactionID,
                    trigger: "navigation_key",
                    observedAt: input.observedAt
                )
                return
            }

            guard configManager.config.captureKeyboardActivity else { return }
            addTypingActivity(
                context: context,
                origin: inputOrigin(from: input),
                count: input.occurrences,
                startedAt: input.observedAt,
                endedAt: input.lastObservedAt,
                sequence: input.sequence,
                nearEventContext: nearEventContext
            )
        }

        private func addTypingActivity(
            context: ContextSnapshot,
            origin: InputOriginSnapshot,
            count: Int,
            startedAt: Date,
            endedAt: Date,
            sequence: UInt64,
            nearEventContext: ContextSnapshot
        ) {
            if typingContext?.fingerprint != context.fingerprint,
                typingCount > 0
            {
                flushTypingBurst()
            }

            if typingCount == 0 {
                let interactionID = UUID().uuidString
                typingInteractionID = interactionID
                typingFirstSequence = sequence
                captureNearEvent(
                    interactionID: interactionID,
                    trigger: "typing",
                    context: nearEventContext
                )
                scheduleTypingAfter(
                    interactionID: interactionID,
                    observedAt: startedAt
                )
            }
            typingContext = context
            typingOrigin = mergeOrigin(typingOrigin, origin)
            if typingStartedAt == nil { typingStartedAt = startedAt }
            typingLastAt = endedAt
            typingCount += max(1, count)
            if let typingInteractionID {
                rescheduleTypingSettled(
                    interactionID: typingInteractionID,
                    observedAt: endedAt
                )
            }

            typingFlushWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.flushTypingBurst()
            }
            typingFlushWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: workItem)
        }

        private func flushTypingBurst() {
            typingFlushWorkItem?.cancel()
            typingFlushWorkItem = nil

            guard typingCount > 0, let context = typingContext else {
                resetTypingBurst()
                return
            }

            let start = typingStartedAt ?? Date()
            let end = typingLastAt ?? start
            let durationMilliseconds = max(0, Int(end.timeIntervalSince(start) * 1_000))
            let interactionID = typingInteractionID ?? UUID().uuidString
            var metadata = interactionMetadata(
                interactionID: interactionID,
                trigger: "typing",
                observedAt: start,
                sequence: typingFirstSequence
            )
            metadata["keystroke_count"] = String(typingCount)
            metadata["duration_ms"] = String(durationMilliseconds)
            metadata["content_recorded"] = "false"
            metadata["input_ended_at_unix_ms"] = String(
                Int64(end.timeIntervalSince1970 * 1_000)
            )

            recorder.record(
                kind: .typingBurst,
                context: context,
                keyboard: KeyboardSnapshot(
                    category: "text_activity",
                    key: nil,
                    modifiers: [],
                    isRepeat: false
                ),
                inputOrigin: typingOrigin,
                metadata: metadata,
                timestamp: end
            )
            resetTypingBurst()
        }

        private func resetTypingBurst() {
            typingCount = 0
            typingStartedAt = nil
            typingLastAt = nil
            typingContext = nil
            typingOrigin = nil
            typingInteractionID = nil
            typingFirstSequence = nil
        }

        private func flushScrollBurst() {
            scrollFlushWorkItem?.cancel()
            scrollFlushWorkItem = nil

            guard scrollEventCount > 0, let context = scrollContext else {
                resetScrollBurst()
                return
            }
            let interactionID = scrollInteractionID ?? UUID().uuidString
            let end = scrollLastAt ?? scrollStartedAt ?? Date()

            recorder.record(
                kind: .scrollBurst,
                context: context,
                scroll: ScrollSnapshot(
                    deltaX: scrollDeltaX,
                    deltaY: scrollDeltaY,
                    eventCount: scrollEventCount
                ),
                inputOrigin: scrollOrigin,
                metadata: interactionMetadata(
                    interactionID: interactionID,
                    trigger: "scroll",
                    observedAt: scrollStartedAt ?? end,
                    sequence: scrollFirstSequence
                ),
                timestamp: end
            )
            resetScrollBurst()
        }

        private func resetScrollBurst() {
            scrollDeltaX = 0
            scrollDeltaY = 0
            scrollEventCount = 0
            scrollStartedAt = nil
            scrollLastAt = nil
            scrollContext = nil
            scrollOrigin = nil
            scrollInteractionID = nil
            scrollFirstSequence = nil
        }

        private func captureNearEvent(
            interactionID: String,
            trigger: String,
            context: ContextSnapshot
        ) {
            ActivityAnalysisRuntime.shared.captureInteractionContext(
                interactionID: interactionID,
                phase: ComputerHistoryMetadata.Phase.nearEvent,
                trigger: trigger,
                context: context
            )
        }

        private func captureAfter(
            interactionID: String,
            trigger: String,
            observedAt: Date
        ) {
            let elapsed = max(0, Date().timeIntervalSince(observedAt))
            scheduleOwnedSemanticCapture(
                interactionID: interactionID,
                phase: ComputerHistoryMetadata.Phase.after,
                trigger: trigger,
                delay: max(0, 0.28 - elapsed)
            )
            scheduleOwnedSemanticCapture(
                interactionID: interactionID,
                phase: ComputerHistoryMetadata.Phase.settled,
                trigger: trigger,
                delay: max(0, 1.05 - elapsed)
            )
        }

        private func scheduleOwnedSemanticCapture(
            interactionID: String,
            phase: String,
            trigger: String,
            delay: TimeInterval
        ) {
            while deferredSemanticCaptureOrder.count >= Self.maximumDeferredSemanticCaptures {
                let oldest = deferredSemanticCaptureOrder.removeFirst()
                deferredSemanticCaptures.removeValue(forKey: oldest)?.cancel()
            }

            let token = UUID()
            let boundaryGeneration = interactionBoundaryGeneration
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let wasPending = self.deferredSemanticCaptures.removeValue(forKey: token) != nil
                self.deferredSemanticCaptureOrder.removeAll { $0 == token }
                guard wasPending,
                    self.interactionBoundaryGeneration == boundaryGeneration
                else { return }
                ActivityAnalysisRuntime.shared.captureInteractionContext(
                    interactionID: interactionID,
                    phase: phase,
                    trigger: trigger
                )
            }
            deferredSemanticCaptures[token] = workItem
            deferredSemanticCaptureOrder.append(token)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0, delay),
                execute: workItem
            )
        }

        private func scheduleTypingAfter(
            interactionID: String,
            observedAt: Date
        ) {
            typingAfterWorkItem?.cancel()
            let elapsed = max(0, Date().timeIntervalSince(observedAt))
            let boundaryGeneration = interactionBoundaryGeneration
            let workItem = DispatchWorkItem { [weak self] in
                guard self?.interactionBoundaryGeneration == boundaryGeneration else { return }
                ActivityAnalysisRuntime.shared.captureInteractionContext(
                    interactionID: interactionID,
                    phase: ComputerHistoryMetadata.Phase.after,
                    trigger: "typing"
                )
            }
            typingAfterWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0, 0.28 - elapsed),
                execute: workItem
            )
        }

        private func scheduleScrollAfter(
            interactionID: String,
            observedAt: Date
        ) {
            scrollAfterWorkItem?.cancel()
            let elapsed = max(0, Date().timeIntervalSince(observedAt))
            let boundaryGeneration = interactionBoundaryGeneration
            let workItem = DispatchWorkItem { [weak self] in
                guard self?.interactionBoundaryGeneration == boundaryGeneration else { return }
                ActivityAnalysisRuntime.shared.captureInteractionContext(
                    interactionID: interactionID,
                    phase: ComputerHistoryMetadata.Phase.after,
                    trigger: "scroll"
                )
            }
            scrollAfterWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0, 0.28 - elapsed),
                execute: workItem
            )
        }

        private func rescheduleTypingSettled(interactionID: String, observedAt: Date) {
            typingSettledWorkItem?.cancel()
            let workItem = settledWorkItem(
                interactionID: interactionID,
                trigger: "typing",
                boundaryGeneration: interactionBoundaryGeneration
            )
            typingSettledWorkItem = workItem
            let elapsed = max(0, Date().timeIntervalSince(observedAt))
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0, 1.20 - elapsed),
                execute: workItem
            )
        }

        private func rescheduleScrollSettled(interactionID: String, observedAt: Date) {
            scrollSettledWorkItem?.cancel()
            let workItem = settledWorkItem(
                interactionID: interactionID,
                trigger: "scroll",
                boundaryGeneration: interactionBoundaryGeneration
            )
            scrollSettledWorkItem = workItem
            let elapsed = max(0, Date().timeIntervalSince(observedAt))
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0, 1.05 - elapsed),
                execute: workItem
            )
        }

        private func settledWorkItem(
            interactionID: String,
            trigger: String,
            boundaryGeneration: UInt64
        ) -> DispatchWorkItem {
            DispatchWorkItem { [weak self] in
                guard self?.interactionBoundaryGeneration == boundaryGeneration else { return }
                ActivityAnalysisRuntime.shared.captureInteractionContext(
                    interactionID: interactionID,
                    phase: ComputerHistoryMetadata.Phase.settled,
                    trigger: trigger
                )
            }
        }

        private func interactionMetadata(
            interactionID: String,
            trigger: String,
            input: EventTapPendingInput
        ) -> [String: String] {
            interactionMetadata(
                interactionID: interactionID,
                trigger: trigger,
                observedAt: input.observedAt,
                sequence: input.sequence
            )
        }

        private func interactionMetadata(
            interactionID: String,
            trigger: String,
            observedAt: Date,
            sequence: UInt64?
        ) -> [String: String] {
            var metadata = [
                ComputerHistoryMetadata.interactionID: interactionID,
                ComputerHistoryMetadata.interactionTrigger: trigger,
                "computer_history.input_observed_at_unix_ms": String(
                    Int64(observedAt.timeIntervalSince1970 * 1_000)
                ),
            ]
            if let sequence {
                metadata["computer_history.input_sequence"] = String(sequence)
            }
            return metadata
        }

        private func inputOrigin(from input: EventTapPendingInput) -> InputOriginSnapshot {
            let pid = input.sourceProcessIdentifier
            let uid = input.sourceUserIdentifier
            let stateID = input.sourceStateIdentifier
            let running: NSRunningApplication?
            if pid > 0, pid <= Int64(Int32.max) {
                running = NSRunningApplication(processIdentifier: pid_t(pid))
            } else {
                running = nil
            }

            let assessment: InputOriginAssessment
            if pid > 0 {
                assessment = .softwareAttributed
            } else if stateID == Int64(CGEventSourceStateID.hidSystemState.rawValue) {
                assessment = .hidLike
            } else {
                assessment = .unknown
            }

            return InputOriginSnapshot(
                sourceProcessIdentifier: pid >= 0 ? pid : nil,
                sourceUserIdentifier: uid >= 0 ? uid : nil,
                sourceStateID: stateID,
                sourceProcessName: running?.localizedName,
                sourceBundleIdentifier: running?.bundleIdentifier,
                assessment: assessment
            )
        }

        private func mergeOrigin(_ current: InputOriginSnapshot?, _ incoming: InputOriginSnapshot)
            -> InputOriginSnapshot
        {
            guard let current else { return incoming }
            if current.assessment == .softwareAttributed { return current }
            if incoming.assessment == .softwareAttributed { return incoming }
            if current.assessment == .unknown { return incoming }
            return current
        }
    }

    private enum KeyDescriptor {
        private static let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 50: "`",
        ]

        private static let specialNames: [UInt16: String] = [
            36: "Return",
            48: "Tab",
            51: "Delete",
            53: "Escape",
            71: "KeypadClear",
            76: "KeypadEnter",
            96: "F5",
            97: "F6",
            98: "F7",
            99: "F3",
            100: "F8",
            101: "F9",
            103: "F11",
            105: "F13",
            107: "F14",
            109: "F10",
            111: "F12",
            113: "F15",
            115: "Home",
            116: "PageUp",
            117: "ForwardDelete",
            118: "F4",
            119: "End",
            120: "F2",
            121: "PageDown",
            122: "F1",
            123: "LeftArrow",
            124: "RightArrow",
            125: "DownArrow",
            126: "UpArrow",
        ]

        static func name(for keyCode: UInt16) -> String {
            names[keyCode] ?? specialNames[keyCode] ?? "KeyCode_\(keyCode)"
        }

        static func specialName(for keyCode: UInt16) -> String? {
            specialNames[keyCode]
        }

        static func modifierNames(from flags: CGEventFlags) -> [String] {
            var output: [String] = []
            if flags.contains(.maskCommand) { output.append("command") }
            if flags.contains(.maskControl) { output.append("control") }
            if flags.contains(.maskAlternate) { output.append("option") }
            if flags.contains(.maskShift) { output.append("shift") }
            if flags.contains(.maskSecondaryFn) { output.append("function") }
            if flags.contains(.maskAlphaShift) { output.append("caps_lock") }
            return output
        }
    }
#endif
