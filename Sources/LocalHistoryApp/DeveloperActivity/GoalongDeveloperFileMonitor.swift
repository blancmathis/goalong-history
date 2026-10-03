#if os(macOS)
import Foundation
import CoreServices
import CryptoKit
import LocalHistoryCore

/// Watches only explicitly selected repository roots. No file contents are opened.
final class GoalongDeveloperFileMonitor {
    private let store: GoalongDeveloperStore
    private let queue = DispatchQueue(label: "goalong.developer-files", qos: .utility)
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var projects: [GoalongDeveloperProject] = []
    private var signature = ""
    private var since: UInt64 = 0
    private var lastEvent: UInt64 = 0
    private var replaying = false
    private var bucketStart: Date?
    private var files: [String: Set<String>] = [:]
    private var estimated = false
    private var dirty = false
    private var wroteBucket = false
    private(set) var status: GoalongDeveloperLaneStatus = .disabled
    init(root: URL) { store = GoalongDeveloperStore(root: root) }
    deinit { stop() }
    func start(replayHistory: Bool = true) {
        queue.sync {
            guard stream == nil, !GoalongGlobalPause.isPaused(in: store.root) else { return }
            do {
                projects = try store.configuration().projects
                guard !projects.isEmpty else { status = .noData; return }
                signature = try store.projectSignature
                let cursor = try store.cursor()
                since = replayHistory && cursor?.projectSignature == signature ? cursor!.lastEventID : FSEventsGetCurrentEventId()
                replaying = replayHistory && cursor?.projectSignature == signature
                lastEvent = since
                var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
                let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
                let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
                    guard let info else { return }
                    let monitor = Unmanaged<GoalongDeveloperFileMonitor>.fromOpaque(info).takeUnretainedValue()
                    let strings = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                    monitor.consume(paths: strings, flags: Array(UnsafeBufferPointer(start: flags, count: count)), ids: Array(UnsafeBufferPointer(start: ids, count: count)))
                }
                guard let created = FSEventStreamCreate(nil, callback, &context, Array(Set(projects.flatMap(\.observationRoots))).sorted() as CFArray, since, 30, flags) else { status = .failed("Le suivi des fichiers n’a pas démarré."); return }
                stream = created
                FSEventStreamSetDispatchQueue(created, queue)
                guard FSEventStreamStart(created) else { FSEventStreamInvalidate(created); FSEventStreamRelease(created); stream = nil; status = .failed("Le suivi des fichiers n’a pas démarré."); return }
                status = .ready
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 300, repeating: 300, leeway: .seconds(10))
                timer.setEventHandler { [weak self] in self?.flush(); self?.rotate(at: Date()) }
                self.timer = timer; timer.resume()
            } catch { status = .failed("Les projets de développement sont illisibles.") }
        }
    }
    func stop(discardOffline: Bool = false) {
        queue.sync {
            timer?.cancel(); timer = nil
            if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
            stream = nil
            flush()
            if discardOffline, !signature.isEmpty { try? store.saveCursor(.init(projectSignature: signature, lastEventID: FSEventsGetCurrentEventId())) }
            files.removeAll(); bucketStart = nil; dirty = false; status = .disabled
        }
    }
    func snapshotStatus() -> GoalongDeveloperLaneStatus { queue.sync { status } }
    #if DEBUG
    func synchronizeForTesting() {
        if let stream = queue.sync(execute: { stream }) { FSEventStreamFlushSync(stream) }
        queue.sync { }
    }
    #endif
    static func permits(relativePath: String) -> Bool {
        let ignored: Set<String> = [".git", ".build", "node_modules", "DerivedData", "dist", "build", "cache", "caches", ".cache", ".DS_Store"]
        return !relativePath.split(separator: "/").contains { ignored.contains(String($0)) }
    }
    private func rotate(at now: Date) {
        let day = Calendar.current.startOfDay(for: now)
        let start = day.addingTimeInterval(floor(now.timeIntervalSince(day) / 300) * 300)
        if bucketStart != start {
            flush(); files.removeAll(); bucketStart = start; estimated = replaying; dirty = false; wroteBucket = false
            // Restarting mid-bucket cannot reconstruct the earlier in-memory distinct-file set.
            let old = store.read(day: now).buckets.filter { $0.start == start }
            if !old.isEmpty { estimated = true }
        }
    }
    private func consume(paths: [String], flags: [FSEventStreamEventFlags], ids: [FSEventStreamEventId]) {
        guard !GoalongGlobalPause.isPaused(in: store.root), paths.count == flags.count, ids.count == flags.count else { return }
        rotate(at: Date())
        if wroteBucket, let start = bucketStart, store.read(day: start).status == .noData {
            // An explicit deletion must not be reconstructed from the transient distinct set.
            files.removeAll(); dirty = false; wroteBucket = false
        }
        let droppedMask = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
        let changedMask = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod)
        let roots = projects.flatMap { project in project.observationRoots.map { (project, $0) } }
        for index in paths.indices {
            lastEvent = max(lastEvent, ids[index])
            if flags[index] & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { replaying = false; continue }
            if flags[index] & droppedMask != 0 {
                estimated = true; status = .partial; dirty = true
                for project in projects where files[project.id] == nil { files[project.id] = [] }
                continue
            }
            guard flags[index] & UInt32(kFSEventStreamEventFlagItemIsFile) != 0, flags[index] & changedMask != 0 else { continue }
            let path = paths[index]
            guard let matched = roots.filter({ path.hasPrefix($0.1 + "/") }).max(by: { $0.1.count < $1.1.count }) else { continue }
            let project = matched.0
            let relative = String(path.dropFirst(matched.1.count + 1))
            guard Self.permits(relativePath: relative) else { continue }
            let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
            guard files.values.reduce(0, { $0 + $1.count }) < 10_000 else { estimated = true; status = .partial; continue }
            files[project.id, default: []].insert(hash)
            estimated = estimated || replaying; dirty = true
        }
        flush()
    }
    private func flush() {
        guard !signature.isEmpty, !GoalongGlobalPause.isPaused(in: store.root) else { return }
        do {
            let pause = try GoalongGlobalPause.admit(in: store.root)
            if dirty, let start = bucketStart {
                let existing = Dictionary(uniqueKeysWithValues: store.read(day: start).buckets.filter { $0.start == start }.map { ($0.projectID, $0) })
                let rows = files.map { id, values in
                    GoalongFileModificationBucket(projectID: id, start: start, modifiedFiles: min(10_000, max(values.count, existing[id]?.modifiedFiles ?? 0)), estimated: estimated || (existing[id]?.estimated ?? false), lastEventID: lastEvent)
                }
                try GoalongGlobalPause.revalidate(pause, in: store.root)
                try store.append(rows, day: start)
                dirty = false; wroteBucket = true
            }
            try GoalongGlobalPause.revalidate(pause, in: store.root)
            try store.saveCursor(.init(projectSignature: signature, lastEventID: lastEvent))
        } catch { status = .failed("Les compteurs de fichiers n’ont pas été enregistrés.") }
    }
}
#endif
