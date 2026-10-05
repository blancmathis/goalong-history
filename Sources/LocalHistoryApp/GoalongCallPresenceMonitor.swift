#if os(macOS)
import AppKit
import CoreAudio
import CoreMediaIO
import Foundation
import LocalHistoryCore

/// Metadata only: hardware property listeners never open an audio or video stream.
final class GoalongCallPresenceMonitor {
    static let shared = GoalongCallPresenceMonitor(root: AppPaths.applicationSupportDirectory)
    private let root: URL
    private let queue = DispatchQueue(label: "ai.goalong.call-presence", qos: .utility)
    private var enabled = false
    private var config = RecorderConfig.default
    private var active: [String: GoalongCallInterval] = [:]
    private var audioListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var cameraListeners: [(CMIOObjectID, CMIOObjectPropertyAddress, CMIOObjectPropertyListenerBlock)] = []
    private var sourceStatus: GoalongSystemSourceStatus = .disabled
    private var recovered = false
    private var refreshScheduled = false
    private var pendingRebuild = false
    init(root: URL) { self.root = root }

    /// Called from the main thread: asynchronous, so a busy CoreAudio queue never stalls the UI.
    /// The serial queue keeps it ordered before any later `stop()`.
    func configure(enabled: Bool, config: RecorderConfig) {
        queue.async { [self] in
            self.config = config
            let next = enabled && config.effectiveCaptureCallPresence && !GoalongGlobalPause.isPaused(in: root)
            if !next { closeActive(at: Date()); removeListeners(); self.enabled = false; sourceStatus = .disabled; return }
            if self.enabled { refresh(); return }
            self.enabled = true
            recoverInterruptedState()
            installListeners()
            refresh()
        }
    }
    func stop() { queue.sync { closeActive(at: Date()); removeListeners(); enabled = false; sourceStatus = .disabled } }
    /// At quit, the open call is saved if the queue answers within `timeout`; the app never
    /// hangs on quit (0.6.64 hung there forever, blocking its own update).
    func stopForTermination(timeout: TimeInterval = 1) {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in closeActive(at: Date()); removeListeners(); enabled = false; sourceStatus = .disabled; done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }
    func lane(day: Date, enabled: Bool, privacy: GoalongPrivacyPolicy = .init()) -> GoalongCallLane {
        queue.sync {
            let live = self.enabled ? active.values.map {
                GoalongCallInterval(start: $0.start, end: Date(), bundleIdentifier: $0.bundleIdentifier,
                    application: $0.application, microphone: $0.microphone, camera: $0.camera)
            } : []
            let value = GoalongCallStore.load(root: root, day: day, enabled: enabled, live: live, privacy: privacy)
            // Today's coverage cannot be inferred from an empty file; older days keep their stored status.
            if enabled, self.enabled, Calendar.current.isDateInToday(day) {
                if case .failed = sourceStatus { return .init(status: sourceStatus, intervals: value.intervals) }
                if sourceStatus == .partial, value.status == .ready || value.status == .noData {
                    return .init(status: .partial, intervals: value.intervals)
                }
            }
            return value
        }
    }
    private func recoverInterruptedState() {
        guard !recovered else { return }; recovered = true
        do {
            if let data = try GoalongSystemSourceFiles.read(root: root, folder: "calls", name: "state.json", maximumBytes: 64_000) {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let previous = try decoder.decode([GoalongCallInterval].self, from: data)
                guard previous.count <= 128 else { throw CocoaError(.fileReadCorruptFile) }
                // A stale open interval is never extrapolated over a stopped/crashed recorder.
                for row in previous {
                    try persistInterval(.init(start: row.start, end: max(row.start, row.end), bundleIdentifier: row.bundleIdentifier,
                        application: row.application, microphone: row.microphone, camera: row.camera, interrupted: true))
                }
            }
            try persistState()
        } catch { sourceStatus = .failed("État micro/caméra illisible." ) }
    }
    static func lane(root: URL, day: Date, enabled: Bool, privacy: GoalongPrivacyPolicy) -> GoalongCallLane {
        if root.standardizedFileURL == shared.root.standardizedFileURL { return shared.lane(day: day, enabled: enabled, privacy: privacy) }
        return GoalongCallStore.load(root: root, day: day, enabled: enabled, privacy: privacy)
    }
    private func persistInterval(_ row: GoalongCallInterval) throws {
        let privacy = GoalongPrivacyPolicy.load(in: root)
        guard !privacy.excludes(appID: row.bundleIdentifier, name: row.application),
              !privacy.hasExclusions || row.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        try GoalongCallStore.save(row, root: root)
    }
    private func persistState() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try GoalongSystemSourceFiles.write(encoder.encode(Array(active.values)), root: root, folder: "calls", name: "state.json", maximumBytes: 64_000)
    }
    private func closeActive(at end: Date) {
        guard enabled || !active.isEmpty else { return }
        for row in active.values {
            do {
                try persistInterval(.init(start: row.start, end: max(row.start, end), bundleIdentifier: row.bundleIdentifier,
                    application: row.application, microphone: row.microphone, camera: row.camera))
            } catch { sourceStatus = .failed("Écriture micro/caméra incomplète.") }
        }
        active.removeAll(); do { try persistState() } catch { sourceStatus = .failed("Écriture micro/caméra incomplète.") }
    }
    private func removeListeners() {
        for (id, address, block) in audioListeners { var a = address; AudioObjectRemovePropertyListenerBlock(id, &a, queue, block) }
        for (id, address, block) in cameraListeners { var a = address; CMIOObjectRemovePropertyListenerBlock(id, &a, queue, block) }
        audioListeners.removeAll(); cameraListeners.removeAll()
    }
    private func audioListen(_ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        guard !audioListeners.contains(where: { $0.0 == object && $0.1.mSelector == selector && $0.1.mScope == scope }) else { return }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRefresh(rebuild: selector == kAudioHardwarePropertyDevices || selector == kAudioHardwarePropertyProcessObjectList) }
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr { audioListeners.append((object, address, block)) }
        else { sourceStatus = .partial }
    }
    private func cameraListen(_ object: CMIOObjectID, selector: CMIOObjectPropertySelector) {
        guard !cameraListeners.contains(where: { $0.0 == object && $0.1.mSelector == selector }) else { return }
        var address = CMIOObjectPropertyAddress(mSelector: selector, mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRefresh(rebuild: selector == UInt32(kCMIOHardwarePropertyDevices)) }
        if CMIOObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr { cameraListeners.append((object, address, block)) }
        else { sourceStatus = .partial }
    }
    private func audioIDs(selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes) == noErr,
              bytes <= 4096 * 4 else { sourceStatus = .partial; return [] }
        if bytes == 0 { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(bytes) / 4)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, $0.baseAddress!) }
        guard status == noErr else { sourceStatus = .partial; return [] }; return ids
    }
    private func cameras() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOHardwarePropertyDevices), mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
        var bytes: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &bytes) == noErr, bytes <= 4096 * 4 else { sourceStatus = .partial; return [] }
        if bytes == 0 { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(bytes) / 4)
        let status = ids.withUnsafeMutableBytes { CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, bytes, &bytes, $0.baseAddress!) }
        guard status == noErr else { sourceStatus = .partial; return [] }; return ids
    }
    private func audioValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, value: inout T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let result = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        if result != noErr { sourceStatus = .partial }; return result == noErr
    }
    private func isInputOnlyDevice(_ object: AudioObjectID) -> Bool {
        func streamBytes(scope: AudioObjectPropertyScope) -> UInt32? {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            return AudioObjectGetPropertyDataSize(object, &address, 0, nil, &bytes) == noErr ? bytes : nil
        }
        guard let input = streamBytes(scope: kAudioDevicePropertyScopeInput) else { sourceStatus = .partial; return false }
        guard input > 0 else { return false }
        // The old hardware running bit has no direction. Duplex devices cannot prove microphone use.
        guard let output = streamBytes(scope: kAudioDevicePropertyScopeOutput), output == 0 else { sourceStatus = .partial; return false }
        return true
    }
    /// Audio processes come and go in bursts (a browser test run starts dozens a second). One
    /// coalesced refresh keeps this queue short, so stop() and lane(), which wait on it from the
    /// main thread, never queue behind minutes of listener rebuilds.
    private func scheduleRefresh(rebuild: Bool) {
        pendingRebuild = pendingRebuild || rebuild
        guard !refreshScheduled else { return }
        refreshScheduled = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let rebuild = pendingRebuild
            refreshScheduled = false; pendingRebuild = false
            refresh(rebuild: rebuild)
        }
    }
    /// Only listeners of vanished objects are removed; live ones are kept rather than rebuilt.
    private func pruneVanishedListeners() {
        var liveAudio = Set(audioIDs(selector: kAudioHardwarePropertyDevices)); liveAudio.insert(AudioObjectID(kAudioObjectSystemObject))
        if #available(macOS 14.2, *) { liveAudio.formUnion(audioIDs(selector: kAudioHardwarePropertyProcessObjectList)) }
        audioListeners.removeAll { id, address, block in
            guard !liveAudio.contains(id) else { return false }
            var a = address; AudioObjectRemovePropertyListenerBlock(id, &a, queue, block); return true
        }
        var liveCameras = Set(cameras()); liveCameras.insert(CMIOObjectID(kCMIOObjectSystemObject))
        cameraListeners.removeAll { id, address, block in
            guard !liveCameras.contains(id) else { return false }
            var a = address; CMIOObjectRemovePropertyListenerBlock(id, &a, queue, block); return true
        }
    }
    private func installListeners() {
        audioListen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices)
        if #available(macOS 14.2, *) {
            audioListen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList)
            for id in audioIDs(selector: kAudioHardwarePropertyProcessObjectList) { audioListen(id, selector: kAudioProcessPropertyIsRunningInput) }
        } else {
            for id in audioIDs(selector: kAudioHardwarePropertyDevices) where isInputOnlyDevice(id) { audioListen(id, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) }
        }
        cameraListen(CMIOObjectID(kCMIOObjectSystemObject), selector: UInt32(kCMIOHardwarePropertyDevices))
        for id in cameras() { cameraListen(id, selector: UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere)) }
    }
    static func application(pid: pid_t, reportedBundle: String?) -> (String?, String?) {
        let running = NSRunningApplication(processIdentifier: pid)
        if let url = running?.bundleURL {
            let parts = url.pathComponents
            if let index = parts.firstIndex(where: { $0.hasSuffix(".app") }), let bundle = Bundle(path: NSString.path(withComponents: Array(parts.prefix(index + 1)))) {
                return (bundle.bundleIdentifier, (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String))
            }
        }
        let raw = running?.bundleIdentifier ?? reportedBundle
        let mapped = raw?.replacingOccurrences(of: #"(?i)(\.helper|\.renderer|\.gpu)(\..*)?$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let bundle = mapped?.isEmpty == false ? mapped : nil
        return (bundle, running?.localizedName ?? bundle)
    }
    private func refresh(rebuild: Bool = false) {
        guard enabled else { return }
        if GoalongGlobalPause.isPaused(in: root) { closeActive(at: Date()); removeListeners(); enabled = false; sourceStatus = .disabled; return }
        if rebuild { pruneVanishedListeners(); installListeners() }
        if case .failed = sourceStatus {} else if sourceStatus != .partial { sourceStatus = .ready }
        let privacy = GoalongPrivacyPolicy.load(in: root)
        var next: [String: GoalongCallInterval] = [:]
        let now = Date()
        if #available(macOS 14.2, *) {
            for id in audioIDs(selector: kAudioHardwarePropertyProcessObjectList) {
                var input: UInt32 = 0
                guard audioValue(id, kAudioProcessPropertyIsRunningInput, value: &input), input != 0 else { continue }
                var pid: pid_t = 0; var reported: CFString = "" as CFString
                _ = audioValue(id, kAudioProcessPropertyPID, value: &pid); _ = audioValue(id, kAudioProcessPropertyBundleID, value: &reported)
                let app = Self.application(pid: pid, reportedBundle: reported as String)
                guard config.allowsApplication(bundleIdentifier: app.0), !privacy.excludes(appID: app.0, name: app.1) else { continue }
                if config.browserBundleIdentifiers.contains(app.0 ?? ""), !config.excludedDomains.isEmpty || !privacy.domains.isEmpty || config.includedDomains?.isEmpty == false { sourceStatus = .partial; continue }
                let key = app.0 ?? "microphone"
                next[key] = .init(start: now, end: now, bundleIdentifier: app.0, application: app.1, microphone: true, camera: false)
            }
        } else {
            for id in audioIDs(selector: kAudioHardwarePropertyDevices) where isInputOnlyDevice(id) {
                var input: UInt32 = 0
                if audioValue(id, kAudioDevicePropertyDeviceIsRunningSomewhere, value: &input), input != 0, !privacy.hasExclusions, config.includedBundleIdentifiers?.isEmpty != false {
                    next["microphone"] = .init(start: now, end: now, bundleIdentifier: nil, application: nil, microphone: true, camera: false)
                }
            }
        }
        for id in cameras() {
            var address = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere), mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
            var size: UInt32 = 4; var value: UInt32 = 0
            let cameraRead = CMIOObjectGetPropertyData(id, &address, 0, nil, 4, &size, &value)
            if cameraRead != noErr { sourceStatus = .partial }
            if cameraRead == noErr, value != 0, !privacy.hasExclusions, config.includedBundleIdentifiers?.isEmpty != false {
                next["camera"] = .init(start: now, end: now, bundleIdentifier: nil, application: nil, microphone: false, camera: true)
            }
        }
        guard Set(next.keys) != Set(active.keys) else {
            // Last confirmed time lives only in memory until a genuine state transition.
            active = active.mapValues { .init(start: $0.start, end: now, bundleIdentifier: $0.bundleIdentifier,
                application: $0.application, microphone: $0.microphone, camera: $0.camera) }
            return
        }
        for (key, value) in active where next[key] == nil {
            do { try persistInterval(.init(start: value.start, end: now, bundleIdentifier: value.bundleIdentifier,
                application: value.application, microphone: value.microphone, camera: value.camera)) }
            catch { sourceStatus = .failed("Écriture micro/caméra incomplète.") }
        }
        for key in next.keys { if let old = active[key] {
            next[key] = .init(start: old.start, end: now, bundleIdentifier: old.bundleIdentifier,
                application: old.application, microphone: old.microphone, camera: old.camera)
        } }
        active = next
        do { try persistState() } catch { sourceStatus = .failed("Écriture micro/caméra incomplète.") }
    }
}
#endif
