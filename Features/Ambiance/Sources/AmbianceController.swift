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
        guard sources.contains(where: { $0.id == source.id && $0.kind == source.kind && $0.isAvailable }) else {
            state = .error(AmbianceError.unavailable.localizedDescription); return
        }
        // Do not publish .playing when no device can be started under the audit.
        state = .error(AmbianceError.audioBoundary.localizedDescription)
    }
    public func stop() { runtime?.stop(); runtime = nil; state = .idle }
    public func shutdown() {
        stop()
        for task in downloadTasks.values { task.cancel() }
        downloadTasks.removeAll(); downloadTickets.removeAll()
        sources = []; packs = []
    }
    deinit { for task in downloadTasks.values { task.cancel() } }
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
        guard let folder = ProcessInfo.processInfo.environment["GOALONG_AMBIANCE_PACK_DIR"], folder.hasPrefix("/") else {
            setStatus(id, .failed(AmbianceError.networkBoundary.localizedDescription)); return
        }
        let archive = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(id + ".tar")
        let ticket = UUID(), store = self.store
        downloadTickets[id] = ticket; setStatus(id, .downloading(0))
        downloadTasks[id] = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                try store.install(pack, archive: archive) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloadTickets[id] == ticket else { return }
                        self.setStatus(id, .downloading(progress))
                    }
                }
            }
            do {
                try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, self.downloadTickets[id] == ticket else { return }
                self.downloadTickets[id] = nil; self.downloadTasks[id] = nil; self.refresh()
            } catch {
                guard let self, self.downloadTickets[id] == ticket else { return }
                self.downloadTickets[id] = nil; self.downloadTasks[id] = nil
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
    public func addOwnFiles(_ urls: [URL]) {
        guard settings.isEnabled else { return }
        let extensions: Set<String> = ["wav", "aiff", "aif", "m4a", "mp3", "caf", "flac"]
        var paths = settings.ownFiles
        func include(_ file: URL) {
            guard extensions.contains(file.pathExtension.lowercased()) else { return }
            let path = file.resolvingSymlinksInPath().standardizedFileURL.path
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, !paths.contains(path) { paths.append(path) }
        }
        for url in urls where url.isFileURL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    while let file = files.nextObject() as? URL { include(file) }
                }
            } else {
                include(url)
            }
        }
        settings.ownFiles = paths; refreshSources()
    }
    public func removeOwnFile(_ source: AmbianceSource) {
        guard settings.isEnabled else { return }
        guard source.kind == .ownFile, let path = source.path else { return }
        settings.ownFiles = settings.ownFiles.filter { $0 != path }; refreshSources()
    }
    public func refresh() {
        guard settings.isEnabled else { shutdown(); return }
        packs = AmbiancePackCatalog.packs.map { pack in
            let pending = packs.first(where: { $0.id == pack.id })?.status
            let absent: AmbiancePackState.Status
            switch pending {
            case .downloading(let progress): absent = .downloading(progress)
            case .failed(let message): absent = .failed(message)
            default: absent = .notInstalled
            }
            return AmbiancePackState(id: pack.id, title: pack.title, bytes: pack.bytes,
                                     status: store.isInstalled(pack) ? .installed : absent)
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
