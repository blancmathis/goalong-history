#if os(macOS)
import Foundation

/// The keyboard backlight as Goalong sees it: read the level, write one, hear every change.
protocol KeyboardBrightnessDriving: AnyObject {
    var isAvailable: Bool { get }
    func brightness() -> Double?
    @discardableResult func setBrightness(_ value: Double) -> Bool
    /// Calls `handler` (any thread) when the level changes, from any process. One observer at a time.
    func observe(_ handler: @escaping @Sendable () -> Void)
    func stopObserving()
}

/// macOS has no public keyboard-backlight API: `CoreBrightness.framework` (private) is opened with `dlopen` and its
/// `KeyboardBrightnessClient` class is driven through the Objective-C runtime, as Control Center does. A missing
/// framework, class or method leaves the driver unavailable: the setting says so and nothing is written. Inert under
/// XCTest. Measured on 2026-11-12 (T-060): 0.01 lights the keys at 0.25 nit, macOS's first step (1/16) at 1.01 nit.
final class CoreBrightnessKeyboard: KeyboardBrightnessDriving, @unchecked Sendable {
    static let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
    private typealias IDsFn = @convention(c) (AnyObject, Selector) -> Unmanaged<NSArray>?
    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias ObserveFn = @convention(c) (AnyObject, Selector, NSArray, UInt64, AnyObject) -> Void
    private typealias StopFn = @convention(c) (AnyObject, Selector) -> Void
    private static let observedKeys = ["KeyboardBacklightBrightness"] as NSArray

    private let client: NSObject?
    private let keyboard: UInt64?
    private let observing = NSLock()
    private var observer = false

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let underTests = NSClassFromString("XCTestCase") != nil || environment["XCTestConfigurationFilePath"] != nil
        guard !underTests, dlopen(Self.path, RTLD_LAZY) != nil,
              let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { client = nil; keyboard = nil; return }
        let needed = ["copyKeyboardBacklightIDs", "brightnessForKeyboard:", "setBrightness:forKeyboard:",
                      "registerNotificationForKeys:keyboardID:block:", "unregisterKeyboardNotificationBlock"]
        guard needed.allSatisfy({ type.instancesRespond(to: NSSelectorFromString($0)) }) else { client = nil; keyboard = nil; return }
        let made = type.init()
        let select = NSSelectorFromString("copyKeyboardBacklightIDs")
        let ids = unsafeBitCast(made.method(for: select), to: IDsFn.self)(made, select)?.takeRetainedValue() as? [NSNumber]
        // The built-in keyboard comes first; an external one with its own light is not managed (none measured).
        client = made
        keyboard = ids?.first?.uint64Value
    }

    var isAvailable: Bool { client != nil && keyboard != nil }

    func brightness() -> Double? {
        guard let client, let keyboard else { return nil }
        let select = NSSelectorFromString("brightnessForKeyboard:")
        let value = unsafeBitCast(client.method(for: select), to: GetFn.self)(client, select, keyboard)
        return value.isFinite ? Double(value) : nil
    }

    @discardableResult func setBrightness(_ value: Double) -> Bool {
        guard let client, let keyboard, value.isFinite else { return false }
        let select = NSSelectorFromString("setBrightness:forKeyboard:")
        return unsafeBitCast(client.method(for: select), to: SetFn.self)(client, select, Float(min(max(value, 0), 1)), keyboard)
    }

    func observe(_ handler: @escaping @Sendable () -> Void) {
        guard let client, let keyboard else { return }
        stopObserving()
        let block: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in handler() }
        let select = NSSelectorFromString("registerNotificationForKeys:keyboardID:block:")
        unsafeBitCast(client.method(for: select), to: ObserveFn.self)(client, select, Self.observedKeys, keyboard, block as AnyObject)
        observing.withLock { observer = true }
    }

    func stopObserving() {
        guard let client, observing.withLock({ let was = observer; observer = false; return was }) else { return }
        let select = NSSelectorFromString("unregisterKeyboardNotificationBlock")
        unsafeBitCast(client.method(for: select), to: StopFn.self)(client, select)
    }
}
#endif
