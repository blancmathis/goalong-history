#if os(macOS)
import Foundation
import LocalHistoryCore

/// Small lifecycle adapter: consent/project changes and global pause restart the watcher.
final class GoalongDeveloperRuntime {
    private let monitor: GoalongDeveloperFileMonitor
    private let consents: GoalongCapabilityConsentStore
    private let root: URL
    private var observers: [NSObjectProtocol] = []
    private var previouslyEnabled = false
    init(root: URL = AppPaths.applicationSupportDirectory, consents: GoalongCapabilityConsentStore = .shared) {
        self.root = root; self.consents = consents; monitor = .init(root: root)
        for name in [Notification.Name.goalongCapabilityConsentDidChange, .goalongGlobalPauseDidChange, .goalongDeveloperProjectsDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in self?.refresh(projectsChanged: notification.name == .goalongDeveloperProjectsDidChange) })
        }
        refresh(initial: true)
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) }; monitor.stop() }
    func stop() { monitor.stop() }
    func status() -> GoalongDeveloperLaneStatus { monitor.snapshotStatus() }
    private func refresh(initial: Bool = false, projectsChanged: Bool = false) {
        let enabled = consents.isEnabled(.developerActivity) && !GoalongGlobalPause.isPaused(in: root)
        if !enabled { monitor.stop(discardOffline: true) }
        else if initial || projectsChanged || !previouslyEnabled {
            monitor.stop()
            monitor.start(replayHistory: initial || projectsChanged)
        }
        previouslyEnabled = enabled
    }
}
#endif
