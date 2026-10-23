import Combine
import Foundation
import OndeCore

@MainActor public final class AmbianceController: ObservableObject {
    public enum State: Equatable { case idle, loading, playing(AmbianceSource), error(String) }
    @Published public private(set) var state: State = .idle
    @Published public private(set) var sources: [AmbianceSource] = []
    @Published public private(set) var packs: [AmbiancePackState] = []
    @Published public var volume: Double {
        didSet {
            let clamped = AmbianceSettings.clamp(volume)
            if clamped != volume { volume = clamped }
            settings.volume = clamped; runtime?.volume = clamped
        }
    }
    private let settings: AmbianceSettings
    private let store: AmbiancePackStore
    private var runtime: AmbianceRuntime?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var downloadTickets: [String: UUID] = [:]
    @Published public private(set) var importNotice: String?
    private var importTasks: [UUID: Task<Void, Never>] = [:]
    private var playTask: Task<Void, Never>?
    private var playTicket: UUID?
    init(settings: AmbianceSettings, supportDirectory: URL) {
        precondition(settings.isEnabled)
        self.settings = settings; store = AmbiancePackStore(supportDirectory: supportDirectory)
        volume = settings.volume
        refresh()
    }
    public var diagnostics: AmbianceDiagnostics {
        if let runtime { return runtime.diagnostics }
        var result = AmbianceDiagnostics(); result.residentBytes = AmbianceRuntime.residentBytes(); return result
    }
    public func play(_ source: AmbianceSource) {
        stop()
        guard settings.isEnabled else { state = .error(AmbianceError.disabled.localizedDescription); return }
        refresh()
        guard let canonical = sources.first(where: { $0.id == source.id && $0.kind == source.kind && $0.isAvailable }) else {
            state = .error(AmbianceError.unavailable.localizedDescription); return
        }
        state = .loading
        if canonical.profile != nil, let pack = AmbiancePackCatalog.packs.first(where: { $0.id == "orchestra" }) {
            // Hashing the samples takes a while on a cold disk: keep it off the main actor so the
            // "Préparation…" state shows and the UI stays responsive. Stop or another Play invalidates the ticket.
            let ticket = UUID(), directory = store.directory(pack)
            playTicket = ticket
            playTask = Task { [weak self] in
                let worker = Task.detached(priority: .userInitiated) {
                    try AmbianceRuntime.prepareOrchestra(source: canonical, orchestraDirectory: directory)
                }
                let prepared: AmbianceRuntime.PreparedOrchestra
                do {
                    prepared = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                } catch {
                    guard let self, self.playTicket == ticket else { return }
                    self.playTask = nil; self.playTicket = nil
                    self.state = .error("Lecture impossible : \(error.localizedDescription)")
                    return
                }
                guard let self, self.playTicket == ticket, !Task.isCancelled else { prepared.discard(); return }
                self.playTask = nil; self.playTicket = nil
                self.begin(AmbianceRuntime(prepared: prepared), canonical)
            }
            return
        }
        do {
            let url: URL
            if canonical.kind == .ownFile, let path = canonical.path { url = URL(fileURLWithPath: path) }
            else if canonical.kind == .texture, let pack = AmbiancePackCatalog.packs.first(where: { $0.id == "textures" }) {
                url = store.directory(pack).appendingPathComponent(canonical.id + ".wav")
            } else { throw AmbianceError.unavailable }
            begin(try AmbianceRuntime(fileURL: url, looping: canonical.kind == .texture) { [weak self] in
                self?.stop()
            }, canonical)
        } catch {
            stop(); state = .error("Lecture impossible : \(error.localizedDescription)")
        }
    }
    private func begin(_ prepared: AmbianceRuntime, _ canonical: AmbianceSource) {
        do {
            prepared.volume = volume; runtime = prepared
            prepared.onInterrupted = { [weak self] in self?.outputInterrupted() }
            try prepared.startOutput()
            settings.lastSource = canonical.id; state = .playing(canonical)
        } catch {
            stop(); state = .error("Lecture impossible : \(error.localizedDescription)")
        }
    }
    /// The audio device changed under a playing source: release everything and say so.
    func outputInterrupted() {
        guard case .playing = state else { return }
        stop(); state = .error("Sortie audio modifiée : relancez la lecture.")
    }
    public func stop() {
        playTask?.cancel(); playTask = nil; playTicket = nil
        runtime?.stop(); runtime = nil; state = .idle
    }
    public func shutdown() {
        stop()
        for task in importTasks.values { task.cancel() }
        importTasks.removeAll(); importNotice = nil
        for task in downloadTasks.values { task.cancel() }
        downloadTasks.removeAll(); downloadTickets.removeAll()
        sources = []; packs = []
    }
    deinit { playTask?.cancel(); for task in importTasks.values { task.cancel() }; for task in downloadTasks.values { task.cancel() } }
    /// Explicit diagnostic render. It emits no device audio and always tears
    /// down the runtime, including on validation, decode and render failures.
    public func renderOffline(_ source: AmbianceSource, seconds: Double) throws -> AmbianceRenderMeasure {
        stop()
        guard settings.isEnabled else { throw AmbianceError.disabled }
        refresh()
        guard let canonical = sources.first(where: { $0.id == source.id && $0.kind == source.kind }),
              canonical.isAvailable, canonical.profile != nil,
              let pack = AmbiancePackCatalog.packs.first(where: { $0.id == "orchestra" }) else { throw AmbianceError.unavailable }
        state = .loading
        defer { stop() }
        let prepared = try AmbianceRuntime(source: canonical, orchestraDirectory: store.directory(pack))
        prepared.volume = volume; runtime = prepared
        return try prepared.render(seconds: seconds)
    }
    public func download(_ id: String) {
        guard settings.isEnabled else { return }
        guard let pack = AmbiancePackCatalog.packs.first(where: { $0.id == id }), downloadTasks[id] == nil else { return }
        if store.isInstalled(pack) { refresh(); return }
        let folder = ProcessInfo.processInfo.environment["GOALONG_AMBIANCE_PACK_DIR"]
        let ticket = UUID(), store = self.store
        downloadTickets[id] = ticket; setStatus(id, .downloading(0))
        downloadTasks[id] = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                let remote = folder == nil
                let publish: (Double) -> Void = { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloadTickets[id] == ticket else { return }
                        self.setStatus(id, .downloading(progress))
                    }
                }
                let archive: URL
                if let folder {
                    guard folder.hasPrefix("/") else { throw AmbianceError.invalidPack("dossier local non absolu") }
                    archive = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(id + ".tar")
                } else {
                    archive = try await AmbiancePackDownloader.download(pack) { publish($0 * 0.5) }
                }
                defer { if remote { try? FileManager.default.removeItem(at: archive) } }
                try store.install(pack, archive: archive) { publish(remote ? 0.5 + $0 * 0.5 : $0) }
            }
            do {
                try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, self.downloadTickets[id] == ticket else { return }
                self.downloadTickets[id] = nil; self.downloadTasks[id] = nil; self.refresh()
            } catch {
                guard let self, self.downloadTickets[id] == ticket else { return }
                self.downloadTickets[id] = nil; self.downloadTasks[id] = nil
                // A cancel is the user's own choice: back to idle, not a failure.
                var wasCancelled = error is CancellationError
                if case AmbianceError.cancelled = error { wasCancelled = true }
                if wasCancelled { self.setStatus(id, .notInstalled); self.refresh(); return }
                self.setStatus(id, .failed("Installation impossible : \(error.localizedDescription)")); self.refreshSources()
            }
        }
    }
    public func cancelDownload(_ id: String) {
        downloadTasks[id]?.cancel()
        // Keep the task registered until cancellation completes, so a retry or
        // remove cannot race a still-extracting worker.
    }
    public func remove(_ id: String) {
        guard settings.isEnabled else { return }
        guard let pack = AmbiancePackCatalog.packs.first(where: { $0.id == id }) else { return }
        guard downloadTasks[id] == nil else { cancelDownload(id); return }
        stop()
        do { try store.remove(pack); refresh() }
        catch { setStatus(id, .failed("Suppression impossible : \(error.localizedDescription)")) }
    }
    /// Most own files kept in the list, and most directory entries looked at in one import.
    public nonisolated static let ownFilesLimit = 500
    nonisolated static let visitedEntriesLimit = 50_000
    /// Audio files in `urls` (folders walked recursively), not already in `existing`, without copying anything.
    /// Pure file-system work: runs off the main actor and stops when cancelled.
    public enum Truncation: Equatable { case listFull, walkCapped }
    nonisolated static func collectAudioFiles(_ urls: [URL], existing: [String], limit: Int = ownFilesLimit, visitedLimit: Int = visitedEntriesLimit) -> (paths: [String], truncated: Truncation?) {
        let extensions: Set<String> = ["wav", "aiff", "aif", "m4a", "mp3", "caf", "flac"]
        var seen = Set(existing), added: [String] = [], truncated: Truncation? = nil, visited = 0
        func include(_ file: URL) {
            guard extensions.contains(file.pathExtension.lowercased()) else { return }
            let path = file.resolvingSymlinksInPath().standardizedFileURL.path
            guard !seen.contains(path), (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return }
            if existing.count + added.count >= limit { truncated = .listFull; return }
            seen.insert(path); added.append(path)
        }
        for url in urls where url.isFileURL {
            if Task.isCancelled { break }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                while let file = files.nextObject() as? URL {
                    if Task.isCancelled || truncated != nil { break }
                    visited += 1
                    if visited > visitedLimit { truncated = .walkCapped; break }
                    include(file)
                }
            } else {
                include(url)
            }
        }
        return (added, truncated)
    }
    /// Plain files are added at once; folders are walked off the main actor. The returned task ends when the list is updated.
    @discardableResult public func addOwnFiles(_ urls: [URL]) -> Task<Void, Never>? {
        guard settings.isEnabled else { return nil }
        importNotice = nil
        let hasFolder = urls.contains { url in
            url.isFileURL && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard hasFolder else {
            merge(Self.collectAudioFiles(urls, existing: settings.ownFiles)); return nil
        }
        let existing = settings.ownFiles
        // Imports run side by side: merge() dedups against the current list, so none must cancel another.
        let importID = UUID()
        let task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { Self.collectAudioFiles(urls, existing: existing) }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self, !Task.isCancelled else { return }
            self.importTasks[importID] = nil
            self.merge(result)
        }
        importTasks[importID] = task
        return task
    }
    func merge(_ result: (paths: [String], truncated: Truncation?)) {
        // Folders can take a while: the module may have been turned off, or the list changed, meanwhile.
        guard settings.isEnabled else { return }
        var paths = settings.ownFiles
        let known = Set(paths)
        var truncated = result.truncated
        for path in result.paths where !known.contains(path) {
            if paths.count >= Self.ownFilesLimit { truncated = truncated ?? .listFull; break }
            paths.append(path)
        }
        settings.ownFiles = paths; refreshSources()
        switch truncated {
        case .walkCapped?: importNotice = "Dossier trop volumineux : seule une partie a été parcourue."
        case .listFull?: importNotice = "La liste est pleine (\(Self.ownFilesLimit) fichiers)."
        case nil: break
        }
    }
    public func removeOwnFile(_ source: AmbianceSource) {
        guard settings.isEnabled else { return }
        guard source.kind == .ownFile, let path = source.path else { return }
        settings.ownFiles = settings.ownFiles.filter { $0 != path }; refreshSources()
    }
    public func refresh() {
        guard settings.isEnabled else { shutdown(); return }
        // No install runs: interrupted installs may have left staging folders behind.
        if downloadTasks.isEmpty { store.removeOrphans() }
        packs = AmbiancePackCatalog.packs.map { pack in
            let pending = packs.first(where: { $0.id == pack.id })?.status
            let absent: AmbiancePackState.Status
            switch pending {
            case .downloading(let progress): absent = .downloading(progress)
            case .failed(let message): absent = .failed(message)
            default: absent = .notInstalled
            }
            let installed = store.isInstalled(pack)
            return AmbiancePackState(id: pack.id, title: pack.title, bytes: pack.bytes,
                                     status: installed ? .installed : absent,
                                     hasLeftovers: !installed && store.hasLeftovers(pack))
        }
        refreshSources()
    }
    private func refreshSources() {
        func installed(_ id: String) -> Bool {
            AmbiancePackCatalog.packs.first(where: { $0.id == id }).map(store.isInstalled) ?? false
        }
        let orchestra = installed("orchestra"), textures = installed("textures")
        sources = (FocusCompositions.profiles + RelaxCompositions.profiles).map {
            AmbianceSource(id: $0.id, title: AmbianceSource.compositionTitles[$0.id] ?? $0.id,
                           kind: $0.mode == .focus ? .focus : .relax, isAvailable: orchestra)
        }
        if textures { sources += AmbianceSource.textures.map { AmbianceSource(id: $0.0, title: $0.1, kind: .texture, isAvailable: true) } }
        sources += settings.ownFiles.map {
            AmbianceSource(id: "file:" + $0, title: URL(fileURLWithPath: $0).lastPathComponent, kind: .ownFile,
                           isAvailable: FileManager.default.fileExists(atPath: $0), path: $0)
        }
    }
    private func setStatus(_ id: String, _ status: AmbiancePackState.Status) {
        if let index = packs.firstIndex(where: { $0.id == id }) { packs[index].status = status }
    }
}
