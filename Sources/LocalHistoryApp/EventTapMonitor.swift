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
        monitor.handle(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    final class EventTapMonitor {
        private let recorder: EventRecorder
        private let contextMonitor: ContextMonitor
        private let contextProvider: ContextProvider
        private let state: CaptureState
        private let configManager: ConfigManager
        private let captureHealth: CaptureHealthStore

        private var eventTap: CFMachPort?
        private var runLoopSource: CFRunLoopSource?
        private(set) var isRunning = false

        private var secureInputWasActive = false

        private var typingCount = 0
        private var typingStartedAt: Date?
        private var typingLastAt: Date?
        private var typingContext: ContextSnapshot?
        private var typingOrigin: InputOriginSnapshot?
        private var typingInteractionID: String?
        private var typingFlushWorkItem: DispatchWorkItem?

        private var scrollDeltaX = 0.0
        private var scrollDeltaY = 0.0
        private var scrollEventCount = 0
        private var scrollContext: ContextSnapshot?
        private var scrollOrigin: InputOriginSnapshot?
        private var scrollInteractionID: String?
        private var scrollFlushWorkItem: DispatchWorkItem?

        init(
            recorder: EventRecorder,
            contextMonitor: ContextMonitor,
            contextProvider: ContextProvider,
            state: CaptureState,
            configManager: ConfigManager,
            captureHealth: CaptureHealthStore
        ) {
            self.recorder = recorder
            self.contextMonitor = contextMonitor
            self.contextProvider = contextProvider
            self.state = state
            self.configManager = configManager
            self.captureHealth = captureHealth
        }

        @discardableResult
        func start() -> Bool {
            guard !isRunning else { return true }

            let eventTypes: [CGEventType] = [
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
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

            eventTap = tap
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            isRunning = true
            Diagnostics.write("Event tap created and enabled; waiting for a real input callback")
            captureHealth.markTapEnabled()
            return true
        }

        func stop() {
            flushTypingBurst()
            flushScrollBurst()

            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            if let eventTap {
                CFMachPortInvalidate(eventTap)
            }
            runLoopSource = nil
            eventTap = nil
            isRunning = false
            captureHealth.markTapDisabled("Event tap stopped")
        }

        func handle(type: CGEventType, event: CGEvent) {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                captureHealth.markTapControlCallback()
                captureHealth.markTapDisabled("macOS disabled the event tap")
                if let eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                    captureHealth.markTapEnabled()
                    Diagnostics.write("Event tap was disabled and has been re-enabled")
                }
                return
            }

            // Only mouse, key and scroll callbacks count as proof that input reaches
            // this exact process. Tap lifecycle callbacks never satisfy this signal.
            captureHealth.markInputCallback()
            guard state.isCapturing else { return }
            if IsSecureEventInputEnabled() {
                suppressForSecureInput(using: contextMonitor.latestSnapshot)
                return
            }

            let needsFreshPrivacyCheck: Bool
            switch type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                needsFreshPrivacyCheck = true
            case .scrollWheel:
                needsFreshPrivacyCheck = scrollEventCount == 0
            case .keyDown:
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let isContextChangingKey = event.flags.contains(.maskCommand)
                    || event.flags.contains(.maskControl)
                    || KeyDescriptor.specialName(for: keyCode) != nil
                needsFreshPrivacyCheck = typingCount == 0 || isContextChangingKey
            default:
                needsFreshPrivacyCheck = false
            }

            if needsFreshPrivacyCheck, contextProvider.fastSuppressionReason() != nil {
                flushTypingBurst()
                flushScrollBurst()
                _ = contextMonitor.sampleNow()
                return
            }

            // Keep the event and the captured app/window/page in one atomic sampling
            // decision. A cached snapshot from a previous foreground PID is never used.
            let cachedPID = contextMonitor.latestSnapshot?.app.processIdentifier
            let frontmostPID = contextProvider.frontmostProcessIdentifier()
            let foregroundChanged = cachedPID != frontmostPID
            var context: ContextSnapshot?
            if needsFreshPrivacyCheck || foregroundChanged {
                context = contextMonitor.sampleNow()
            } else {
                context = contextMonitor.latestSnapshot
            }
            if context == nil {
                context = contextMonitor.sampleNow()
            }

            guard let context, context.suppressionReason == nil else { return }
            if context.focusedElement?.isSecure == true {
                suppressForSecureInput(using: context)
                return
            }
            resumeAfterSecureInputIfNeeded(using: context)

            switch type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                handleMouseDown(type: type, event: event, context: context)
            case .scrollWheel:
                handleScroll(event: event, context: context)
            case .keyDown:
                handleKeyDown(event: event, context: context)
            default:
                break
            }
        }

        private func suppressForSecureInput(using context: ContextSnapshot?) {
            flushTypingBurst()
            flushScrollBurst()
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

        private func handleMouseDown(type: CGEventType, event: CGEvent, context: ContextSnapshot) {
            guard configManager.config.captureClicks else { return }
            flushTypingBurst()
            flushScrollBurst()

            let interactionID = UUID().uuidString
            captureBefore(interactionID: interactionID, trigger: "click", context: context)

            let location = event.location
            let clickCount = max(1, Int(event.getIntegerValueField(.mouseEventClickState)))
            let button: String
            switch type {
            case .leftMouseDown: button = "left"
            case .rightMouseDown: button = "right"
            default: button = "other"
            }

            let pointer = PointerSnapshot(
                button: button,
                x: Double(location.x),
                y: Double(location.y),
                clickCount: clickCount
            )
            let target = contextProvider.element(
                at: location,
                expectedProcessIdentifier: context.app.processIdentifier
            )

            recorder.record(
                kind: .mouseClick,
                context: context,
                element: target,
                pointer: pointer,
                inputOrigin: inputOrigin(from: event),
                metadata: interactionMetadata(interactionID: interactionID, trigger: "click")
            )
            captureAfter(interactionID: interactionID, trigger: "click")
        }

        private func handleScroll(event: CGEvent, context: ContextSnapshot) {
            guard configManager.config.captureScroll else { return }

            let deltaY = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            let deltaX = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))

            if scrollContext?.fingerprint != context.fingerprint {
                flushScrollBurst()
            }
            if scrollEventCount == 0 {
                let interactionID = UUID().uuidString
                scrollInteractionID = interactionID
                captureBefore(interactionID: interactionID, trigger: "scroll", context: context)
            }

            scrollContext = context
            scrollOrigin = mergeOrigin(scrollOrigin, inputOrigin(from: event))
            scrollDeltaX += deltaX
            scrollDeltaY += deltaY
            scrollEventCount += 1

            scrollFlushWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.flushScrollBurst()
            }
            scrollFlushWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
        }

        private func handleKeyDown(event: CGEvent, context: ContextSnapshot) {
            flushScrollBurst()
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let modifiers = KeyDescriptor.modifierNames(from: event.flags)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let isShortcut = event.flags.contains(.maskCommand) || event.flags.contains(.maskControl)

            if isShortcut, configManager.config.captureShortcuts {
                flushTypingBurst()
                let interactionID = UUID().uuidString
                captureBefore(interactionID: interactionID, trigger: "shortcut", context: context)
                let keyboard = KeyboardSnapshot(
                    category: "shortcut",
                    key: KeyDescriptor.name(for: keyCode),
                    modifiers: modifiers,
                    isRepeat: isRepeat
                )
                recorder.record(
                    kind: .keyboardShortcut,
                    context: context,
                    keyboard: keyboard,
                    inputOrigin: inputOrigin(from: event),
                    metadata: interactionMetadata(interactionID: interactionID, trigger: "shortcut")
                )
                captureAfter(interactionID: interactionID, trigger: "shortcut")
                return
            }

            if let specialKey = KeyDescriptor.specialName(for: keyCode) {
                flushTypingBurst()
                guard configManager.config.captureKeyboardActivity else { return }
                let interactionID = UUID().uuidString
                captureBefore(interactionID: interactionID, trigger: "navigation_key", context: context)
                let keyboard = KeyboardSnapshot(
                    category: "navigation",
                    key: specialKey,
                    modifiers: modifiers,
                    isRepeat: isRepeat
                )
                recorder.record(
                    kind: .keyPressed,
                    context: context,
                    keyboard: keyboard,
                    inputOrigin: inputOrigin(from: event),
                    metadata: interactionMetadata(interactionID: interactionID, trigger: "navigation_key")
                )
                captureAfter(interactionID: interactionID, trigger: "navigation_key")
                return
            }

            guard configManager.config.captureKeyboardActivity else { return }
            addTypingActivity(context: context, origin: inputOrigin(from: event))
        }

        private func addTypingActivity(context: ContextSnapshot, origin: InputOriginSnapshot) {
            let now = Date()

            if typingContext?.fingerprint != context.fingerprint,
                typingCount > 0
            {
                flushTypingBurst()
            }

            if typingCount == 0 {
                let interactionID = UUID().uuidString
                typingInteractionID = interactionID
                captureBefore(interactionID: interactionID, trigger: "typing", context: context)
            }
            typingContext = context
            typingOrigin = mergeOrigin(typingOrigin, origin)
            if typingStartedAt == nil { typingStartedAt = now }
            typingLastAt = now
            typingCount += 1

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
                metadata: [
                    "keystroke_count": String(typingCount),
                    "duration_ms": String(durationMilliseconds),
                    "content_recorded": "false",
                    ComputerHistoryMetadata.interactionID: interactionID,
                    ComputerHistoryMetadata.interactionTrigger: "typing",
                ],
                timestamp: end
            )
            captureAfter(interactionID: interactionID, trigger: "typing")
            resetTypingBurst()
        }

        private func resetTypingBurst() {
            typingCount = 0
            typingStartedAt = nil
            typingLastAt = nil
            typingContext = nil
            typingOrigin = nil
            typingInteractionID = nil
        }

        private func flushScrollBurst() {
            scrollFlushWorkItem?.cancel()
            scrollFlushWorkItem = nil

            guard scrollEventCount > 0, let context = scrollContext else {
                resetScrollBurst()
                return
            }
            let interactionID = scrollInteractionID ?? UUID().uuidString

            recorder.record(
                kind: .scrollBurst,
                context: context,
                scroll: ScrollSnapshot(
                    deltaX: scrollDeltaX,
                    deltaY: scrollDeltaY,
                    eventCount: scrollEventCount
                ),
                inputOrigin: scrollOrigin,
                metadata: interactionMetadata(interactionID: interactionID, trigger: "scroll")
            )
            captureAfter(interactionID: interactionID, trigger: "scroll")
            resetScrollBurst()
        }

        private func resetScrollBurst() {
            scrollDeltaX = 0
            scrollDeltaY = 0
            scrollEventCount = 0
            scrollContext = nil
            scrollOrigin = nil
            scrollInteractionID = nil
        }

        private func captureBefore(
            interactionID: String,
            trigger: String,
            context: ContextSnapshot
        ) {
            ActivityAnalysisRuntime.shared.captureInteractionContext(
                interactionID: interactionID,
                phase: ComputerHistoryMetadata.Phase.before,
                trigger: trigger,
                context: context
            )
        }

        private func captureAfter(interactionID: String, trigger: String) {
            ActivityAnalysisRuntime.shared.scheduleInteractionContext(
                interactionID: interactionID,
                phase: ComputerHistoryMetadata.Phase.after,
                trigger: trigger,
                delay: 0.28
            )
            ActivityAnalysisRuntime.shared.scheduleInteractionContext(
                interactionID: interactionID,
                phase: ComputerHistoryMetadata.Phase.settled,
                trigger: trigger,
                delay: 1.05
            )
        }

        private func interactionMetadata(interactionID: String, trigger: String) -> [String: String] {
            [
                ComputerHistoryMetadata.interactionID: interactionID,
                ComputerHistoryMetadata.interactionTrigger: trigger,
            ]
        }

        private func inputOrigin(from event: CGEvent) -> InputOriginSnapshot {
            let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
            let uid = event.getIntegerValueField(.eventSourceUserID)
            let stateID = event.getIntegerValueField(.eventSourceStateID)
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

        private func mergeOrigin(_ current: InputOriginSnapshot?, _ incoming: InputOriginSnapshot) -> InputOriginSnapshot {
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
