#if os(macOS)
import AppKit
import Foundation
import GoalongGuardCore

/// `make perso` hands a signed build to the running Goalong (Mathis, 2026-11-22: locked blocks run 24/7 and the
/// installer refuses during one). Perso builds only: a release ignores the inbox. Checks: same bundle id, newer
/// perso build, signature against our own designated requirement and leaf certificate, and during a locked block
/// at most one install per 10 minutes (counted from this instance's launch on a clock that runs during sleep).
/// Then: staged copy beside us, staged relauncher ready, atomic swap, quit as for a Sparkle update. The
/// relauncher reopens the new app and swaps back unless it reports health within 45 s.
@MainActor final class PersoSelfUpdate { // one instance per app
    static let shared = PersoSelfUpdate()
    private let files = PersoUpdateFiles.standard
    private let launchedAt = clock_gettime_nsec_np(CLOCK_MONOTONIC)
    private var watcher: DispatchSourceFileSystemObject?
    private var busy = false
    private var process: Process?
    private var pipe: Pipe?

    static func start() {
        #if GOALONG_PERSO
        shared.begin()
        #endif
    }

    private var secondsSinceLaunch: TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC) &- launchedAt) / 1_000_000_000
    }

    private func begin() {
        guard Bundle.main.bundleIdentifier == PersoUpdate.releaseBundleIdentifier,
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: files.inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        removeStaleStages()
        // The relauncher waits for this before it keeps the new build.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [files] in
            guard let builtAt = PersoBundleFacts.read(app: Bundle.main.bundleURL).builtAt else { return }
            files.writeHealth(.init(pid: getpid(), builtAt: builtAt))
        }
        let fd = open(files.inbox.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan() } }
        source.setCancelHandler { close(fd) }
        source.activate()
        watcher = source
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.scan() }
    }

    private func removeStaleStages() {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasPrefix(PersoUpdate.stagePrefix) {
            let url = parent.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().throttleElapsed(since: modified) > 600 { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func scan() {
        guard !busy, let request = files.pendingRequests().first else { return }
        busy = true
        if let reason = install(request) {
            files.writeResult(request, .init(state: PersoUpdateFiles.Result.refused, reason: reason))
            busy = false
            DispatchQueue.main.async { [weak self] in self?.scan() }
        }
    }

    private static var protectedNow: Bool {
        let runtime = BlockingRuntime.shared
        return runtime.protectedUntil() != nil || runtime.protectedRuleStop() != nil || JevStopGate.protectedStep() != .allow
    }

    /// nil when the swap is done and Goalong is quitting; otherwise why the request was refused.
    private func install(_ request: String) -> String? {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let candidate = files.request(request).appendingPathComponent(target.lastPathComponent, isDirectory: true)
        let running = PersoBundleFacts.read(app: target)
        func policy(_ app: URL) -> String? {
            if case .refuse(let reason) = PersoUpdatePolicy.decide(candidate: PersoBundleFacts.read(app: app), running: running,
                                                                   protected: Self.protectedNow, secondsSinceLaunch: secondsSinceLaunch) {
                return reason
            }
            return nil
        }
        guard fm.fileExists(atPath: candidate.path) else { return "app absente de la demande" }
        if let reason = policy(candidate) { return reason }
        // Check the copy we install, in a folder beside us (same volume, so the swap is atomic).
        let staged = PersoStage.stagedApp(for: target, request: request)
        let stageDir = staged.deletingLastPathComponent()
        try? fm.removeItem(at: stageDir)
        do {
            try fm.createDirectory(at: stageDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            try fm.copyItem(at: candidate, to: staged)
        } catch { try? fm.removeItem(at: stageDir); return "copie impossible à côté de l’app (\(error.localizedDescription))" }
        let fail: (String) -> String = { reason in try? fm.removeItem(at: stageDir); return reason }
        guard let reference = PersoSignature.selfStaticCode() else { return fail("signature de l’app introuvable") }
        if let reason = PersoSignature.check(candidate: staged, reference: reference) { return fail(reason) }
        if let reason = policy(staged) { return fail(reason) }
        files.writeResult(request, .init(state: PersoUpdateFiles.Result.accepted))
        startRelauncher(staged: staged, request: request) { [weak self] error in
            guard let self else { return }
            if let error {
                self.finishRefused(request, stageDir: stageDir, reason: error)
                return
            }
            do { try PersoStage.swap(target, staged) } catch {
                self.process?.terminate()
                self.finishRefused(request, stageDir: stageDir, reason: error.localizedDescription)
                return
            }
            // The guard waits while the relauncher (now at the installed path) lives (spec K §8).
            GoalongGuardFiles.writeLease(GuardLease.update, seconds: GuardLease.maximumDuration)
            SoftwareUpdateManager.shared.markRelaunchingForPersoUpdate()
            NSApplication.shared.terminate(nil)
        }
        return nil
    }

    private func finishRefused(_ request: String, stageDir: URL, reason: String) {
        try? FileManager.default.removeItem(at: stageDir)
        files.writeResult(request, .init(state: PersoUpdateFiles.Result.refused, reason: reason))
        busy = false
    }

    /// Same handshake as PermissionRecovery: the relauncher answers READY once it watches our exit.
    private func startRelauncher(staged: URL, request: String, completion: @escaping (String?) -> Void) {
        let helper = staged.appendingPathComponent("Contents/MacOS/goalong-relauncher")
        guard FileManager.default.isExecutableFile(atPath: helper.path),
              let launched = NSRunningApplication.current.launchDate else { return completion("composant de relance absent") }
        let child = Process()
        child.executableURL = helper
        child.arguments = ["--parent", String(ProcessInfo.processInfo.processIdentifier),
                           "--launched", String(launched.timeIntervalSince1970), "--perso-swap", request]
        child.environment = ProcessInfo.processInfo.environment.filter {
            ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"].contains($0.key)
        }
        child.standardInput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        let output = Pipe()
        child.standardOutput = output
        process = child; pipe = output
        var finished = false, received = Data()
        let finish: @MainActor (String?) -> Void = { [weak self] error in
            guard !finished else { return }
            finished = true
            self?.pipe?.fileHandleForReading.readabilityHandler = nil
            if error != nil, let process = self?.process, process.isRunning { process.terminate() }
            completion(error)
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    received.append(bytes)
                    if received == Data("READY\n".utf8) { finish(nil) }
                    else if bytes.isEmpty || received.count > 32 { finish("le composant de relance a refusé") }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { MainActor.assumeIsolated { finish("le composant de relance n’a pas répondu") } }
        do { try child.run() } catch { finish("relance impossible (\(error.localizedDescription))") }
    }
}
#endif
