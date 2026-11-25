#if os(macOS)
import Combine
import Foundation
import LocalHistoryCore

extension Notification.Name {
    static let goalongFocusCoachSettingsDidChange = Notification.Name("goalong.focus.coach-settings.changed")
}

protocol FocusDayCoachSession: AnyObject {
    func focusDayCoachModels() throws -> [FocusDayCoachModel]
    func readAccountLimits() -> GoalongAccountLimits?
    func generateFocusDayCoach(preview: FocusDayCoachPreview, workingDirectory: URL,
                               beforeSend: @escaping () throws -> Void) throws -> (data: Data, tokens: Int?)
    func close()
}
extension CodexAppServerSession: FocusDayCoachSession {}

private final class FocusDayCoachOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var session: FocusDayCoachSession?
    private var recordedAttempt: UUID?
    var attempt: UUID? { lock.lock(); defer { lock.unlock() }; return recordedAttempt }
    func recordAttempt(_ id: UUID) { lock.lock(); recordedAttempt = id; lock.unlock() }
    func check() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw FocusDayCoachFailure.cancelled }
    }
    func attach(_ value: FocusDayCoachSession) throws {
        lock.lock()
        if cancelled { lock.unlock(); value.close(); throw FocusDayCoachFailure.cancelled }
        session = value; lock.unlock()
    }
    func cancel() {
        lock.lock(); cancelled = true; let value = session; lock.unlock()
        value?.close()
    }
    func close() {
        lock.lock(); let value = session; session = nil; lock.unlock()
        value?.close()
    }
}

/// No timer, polling, startup inference or automatic planning. All network work starts
/// at an explicit model-catalogue or advice action.
@MainActor final class FocusDayCoachRuntime: ObservableObject {
    static let shared = FocusDayCoachRuntime()
    @Published private(set) var models: [FocusDayCoachModel] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isLoadingModels = false
    @Published private(set) var preview: FocusDayCoachPreview?
    @Published private(set) var result: FocusDayCoachResult?
    @Published private(set) var usage: FocusDayCoachUsageStatus?
    @Published private(set) var error: String?

    private let store: FocusDayCoachUsageStore
    private let clock: () -> Date
    private let calendar: Calendar
    private let consent: () -> Bool
    private let privacy: () -> GoalongPrivacyPolicy
    private let selection: () -> GoalongAnalysisSelection
    private let makeSession: () throws -> FocusDayCoachSession
    private var operation: FocusDayCoachOperation?
    private var observers: [NSObjectProtocol] = []

    init(store: FocusDayCoachUsageStore = .standard, clock: @escaping () -> Date = Date.init, // wall: usage accounting only; no stake or blocking decision
         calendar: Calendar = .autoupdatingCurrent,
         consent: @escaping () -> Bool = { GoalongCapabilityConsentStore.shared.isEnabled(.chatGPTAnalysis) },
         privacy: @escaping () -> GoalongPrivacyPolicy = { GoalongPrivacyPolicy.load(in: AppPaths.applicationSupportDirectory) },
         selection: @escaping () -> GoalongAnalysisSelection = { GoalongAnalysisSelection.load() },
         makeSession: @escaping () throws -> FocusDayCoachSession = FocusDayCoachRuntime.defaultSession,
         observeChanges: Bool = true) {
        self.store = store; self.clock = clock; self.calendar = calendar
        self.consent = consent; self.privacy = privacy; self.selection = selection; self.makeSession = makeSession
        if observeChanges {
            for name in [Notification.Name.goalongCapabilityConsentDidChange, .goalongExclusionsDidChange,
                         .goalongAnalysisSelectionDidChange, .goalongFocusCoachSettingsDidChange] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    if name == .goalongCapabilityConsentDidChange,
                       let capability = notification.userInfo?["capability"] as? String,
                       capability != GoalongCapability.chatGPTAnalysis.rawValue { return }
                    Task { @MainActor in self?.invalidatePreview() }
                })
            }
        }
    }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        operation?.cancel()
    }
    nonisolated static func defaultSession() throws -> FocusDayCoachSession {
        guard let executable = CodexExecutableLocator.locate() else { throw CodexAppServerError.executableUnavailable }
        try ChatGPTSecureStorage.prepareDirectory(AppPaths.chatGPTDirectory)
        return try CodexAppServerSession(executableURL: executable, codexHomeURL: AppPaths.chatGPTCodexHomeDirectory,
                                         siteAnalysisOnly: true, homeLeaseWait: 0)
    }
    /// Read-only local status for UI and CLI; a fresh process cannot reset today's cap.
    func status(settings: FocusDayCoachSettings) throws -> FocusDayCoachUsageStatus {
        guard settings.valid else { throw FocusDayCoachFailure.configureModel }
        return try store.load().status(day: FocusCalendar.dayKey(clock(), calendar: calendar), settings: settings, busy: isBusy)
    }
    func refreshUsage(settings: FocusDayCoachSettings) {
        do { usage = try status(settings: settings) }
        catch { usage = nil; self.error = FocusDayCoachFailure.storage.localizedDescription }
    }
    func discardPreview() { preview = nil }
    func invalidatePreview() {
        preview = nil; result = nil
        if isBusy { cancel() }
    }
    func cancel() {
        operation?.cancel()
        if isBusy { error = FocusDayCoachFailure.cancelled.localizedDescription }
        // Keep the busy latch until the child has actually exited.
    }
    func clearError() { error = nil }

    /// account/read + model/list only. No thread/start or turn/start.
    @discardableResult func loadModels() async throws -> [FocusDayCoachModel] {
        guard consent() else { error = FocusDayCoachFailure.noConsent.localizedDescription; throw FocusDayCoachFailure.noConsent }
        let box = try begin()
        isLoadingModels = true
        defer { finish(box); isLoadingModels = false }
        let factory = makeSession
        do {
            let values = try await Task.detached(priority: .utility) {
                try box.check()
                let session = try factory(); try box.attach(session); defer { box.close() }
                let values = try session.focusDayCoachModels(); try box.check(); return values
            }.value
            guard consent() else { throw FocusDayCoachFailure.noConsent }
            models = values; return values
        } catch { self.error = GoalongUserFacingError.message(error); throw error }
    }

    func preparePreview(controller: ConcentrationController, note: String = "") {
        guard !isBusy else { return }
        error = nil; preview = nil
        do {
            let settings = controller.settings.coachSettings
            try requireReady(settings)
            preview = try FocusDayCoachContext.make(plan: controller.plan, review: controller.review,
                settings: settings, note: note, policy: privacy(), selection: selection())
            refreshUsage(settings: settings)
        } catch { self.error = GoalongUserFacingError.message(error) }
    }

    /// Called only after showing this exact preview. Never applies the answer to the plan.
    func generate(controller: ConcentrationController) async throws {
        let settings = controller.settings.coachSettings
        do { try requireReady(settings) }
        catch { self.error = GoalongUserFacingError.message(error); throw error }
        guard let selected = preview else { error = FocusDayCoachFailure.stalePreview.localizedDescription; throw FocusDayCoachFailure.stalePreview }
        try validate(selected, controller: controller)
        guard try status(settings: settings).remaining > 0 else { error = FocusDayCoachFailure.dailyLimit.localizedDescription; throw FocusDayCoachFailure.dailyLimit }
        let box = try begin()
        result = nil
        defer { finish(box); refreshUsage(settings: controller.settings.coachSettings) }
        let factory = makeSession
        let beforeSend: () throws -> Void = { [weak self, weak controller] in
            try DispatchQueue.main.sync {
                try MainActor.assumeIsolated {
                    guard let self, let controller, self.operation === box else { throw FocusDayCoachFailure.cancelled }
                    try box.check(); try self.validate(selected, controller: controller)
                    let now = self.clock()
                    let id = try self.store.reserve(day: FocusCalendar.dayKey(now, calendar: self.calendar),
                                                    now: now, limit: selected.settings.dailyCallLimit)
                    box.recordAttempt(id)
                    self.refreshUsage(settings: selected.settings)
                }
            }
        }
        do {
            let response = try await Task.detached(priority: .userInitiated) {
                try box.check()
                let session = try factory(); try box.attach(session); defer { box.close() }
                if session.readAccountLimits()?.isNear == true { throw FocusDayCoachFailure.accountLimit }
                try box.check()
                let directory = try GoalongSiteAnalysisModel.makeWorkingDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                return try session.generateFocusDayCoach(preview: selected, workingDirectory: directory, beforeSend: beforeSend)
            }.value
            if let attempt = box.attempt { try store.settle(attempt, tokens: response.tokens) }
            try box.check()
            try requireReady(controller.settings.coachSettings)
            guard controller.settings.coachSettings == selected.settings,
                  privacy().revision == selected.privacyRevision, !privacy().blocked,
                  selection().revision == selected.selectionRevision else { throw FocusDayCoachFailure.selectionChanged }
            let answer = try FocusDayCoachAnswer.parse(response.data, maximumCharacters: selected.settings.maximumOutputCharacters)
            result = .init(answer: answer, generatedAt: clock(), day: selected.day, planRevision: selected.planRevision,
                           model: selected.settings.model!,
                           reasoningEffort: selected.settings.reasoningEffort!, tokens: response.tokens)
        } catch {
            // Reserved attempts remain on disk, including invalid responses and cancellations.
            self.error = GoalongUserFacingError.message(error); throw error
        }
    }

    private func validate(_ value: FocusDayCoachPreview, controller: ConcentrationController) throws {
        let settings = controller.settings.coachSettings
        try requireReady(settings)
        guard settings == value.settings, controller.plan.day == value.day,
              controller.plan.effectiveRevision == value.planRevision else { throw FocusDayCoachFailure.stalePreview }
        // Rebuild and compare: even a review change without a plan revision requires a new preview.
        let current = try FocusDayCoachContext.make(plan: controller.plan, review: controller.review, settings: settings,
                                                    note: value.note, policy: privacy(), selection: selection())
        guard current == value else { throw FocusDayCoachFailure.stalePreview }
    }
    private func requireReady(_ settings: FocusDayCoachSettings) throws {
        guard settings.enabled else { throw FocusDayCoachFailure.disabled }
        guard settings.provider == .chatGPT else { throw FocusDayCoachFailure.externalAgent }
        guard settings.valid, settings.model != nil, settings.reasoningEffort != nil else { throw FocusDayCoachFailure.configureModel }
        guard consent() else { throw FocusDayCoachFailure.noConsent }
    }
    private func begin() throws -> FocusDayCoachOperation {
        guard operation == nil else { throw FocusDayCoachFailure.busy }
        let box = FocusDayCoachOperation(); operation = box; isBusy = true; error = nil; return box
    }
    private func finish(_ box: FocusDayCoachOperation) {
        guard operation === box else { return }
        operation = nil; isBusy = false
    }
}
#endif
