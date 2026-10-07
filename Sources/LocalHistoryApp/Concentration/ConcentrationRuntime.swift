#if os(macOS)
import AppKit
import Combine
import Foundation
import LocalHistoryCore
import LocalHistoryQueryCLI

/// Holds no module object while off. The socket bridge returns moduleDisabled before asking for one.
@MainActor final class ConcentrationRuntime: ObservableObject {
    static let shared = ConcentrationRuntime()
    @Published private(set) var controller: ConcentrationController?
    @Published private(set) var error: String?
    lazy var statusHub = GoalongFocusStatusHub()
    var onOpen: (() -> Void)?
    /// The phase and the minutes left, for the menu bar; `nil` when no session runs.
    var onMenuBarText: ((String?) -> Void)?
    private var menuBarSubscription: AnyCancellable?
    private var menuBarTimer: Timer?
    private var modules: GoalongModuleStore?
    private weak var monitor: ContextMonitor?
    private var presenter: ConcentrationPanelPresenter?
    private let presentsPanels: Bool
    private let storeFactory: () -> FocusStore
    private var measurementTask: Task<Void, Never>?
    private var measurementGeneration = UUID()
    private let blockingProvider: @MainActor () -> BlockingController?
    private let factory: ((FocusStore) throws -> ConcentrationController)?
    private let clock: () -> Date
    private let calendar: Calendar
    init(storeFactory: @escaping () -> FocusStore = { .standard }, factory: ((FocusStore) throws -> ConcentrationController)? = nil, blockingProvider: @escaping @MainActor () -> BlockingController? = { BlockingRuntime.shared.controller }, presentsPanels: Bool = true, clock: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.storeFactory = storeFactory; self.factory = factory; self.blockingProvider = blockingProvider; self.presentsPanels = presentsPanels
        self.clock = clock; self.calendar = calendar
    }
    func start(modules: GoalongModuleStore = .shared, monitor: ContextMonitor? = nil) {
        self.modules = modules; self.monitor = monitor
        modules.concentrationDisableCheck = { [weak self] in self?.controller?.refresh(); return self?.controller?.hasLockedBlock != true }
        modules.onConcentrationEnabledChange = { [weak self] in self?.apply(enabled: $0) }
        apply(enabled: modules.isEnabled(.concentration))
    }
    func apply(enabled: Bool) {
        if enabled, controller == nil {
            do {
                let store = storeFactory()
                let value = try factory?(store) ?? ConcentrationController(store: store, clock: clock, calendar: calendar, blocking: blockingProvider, runsTimers: true)
                controller = value; error = nil
                NotificationCenter.default.post(name: .goalongFocusSessionDidChange, object: self)
                value.onStatusChange = { [weak self] status in if let data = try? FocusJSON.encode(status) { self?.statusHub.publish(data) } }
                statusHub.publish(try FocusJSON.encode(value.status))
                value.onPanelChange = { [weak self, weak value] panel in
                    guard let self, let value, self.presentsPanels else { return }
                    if let panel { let p = self.presenter ?? ConcentrationPanelPresenter(); p.show(panel, controller: value); self.presenter = p }
                    else { self.presenter?.close(); self.presenter = nil }
                }
                value.onPhaseSound = { NSSound(named: "Glass")?.play() }
                value.onOpenRequested = { [weak self] _ in self?.onOpen?() }
                value.onLimitMark = { [weak self] mark in self?.monitor?.recordFocusLimit(mark) }
                value.measurementRefresh = { [weak self] in self?.refreshMeasurements() }
                monitor?.concentrationSink = { [weak self, weak value] observation in
                    value?.observe(observation)
                    if !observation.observing { self?.measurementTask?.cancel(); self?.measurementTask = nil; self?.measurementGeneration = UUID() }
                }
                if let panel = value.panel { value.onPanelChange?(panel) }
                menuBarSubscription = value.$phase.combineLatest(value.$currentSession).sink { [weak self] phase, session in
                    self?.updateMenuBar(phase: phase, session: session)
                }
                refreshMeasurements()
            } catch { self.error = String(describing: error) }
        } else if !enabled, let controller {
            controller.refresh()
            if controller.hasLockedBlock { modules?.setEnabled(.concentration, true); error = FocusFailure.locked.rawValue; return }
            measurementTask?.cancel(); measurementTask = nil; measurementGeneration = UUID()
            controller.shutdown(); monitor?.concentrationSink = nil
            menuBarSubscription = nil; menuBarTimer?.invalidate(); menuBarTimer = nil; onMenuBarText?(nil)
            presenter?.close(); presenter = nil; self.controller = nil
            NotificationCenter.default.post(name: .goalongFocusSessionDidChange, object: self)
        }
    }
    func noteInput(at: Date, count: Int) { controller?.noteInput(at: at, count: count) }
    /// Minutes, not seconds: one wake per minute while a session runs, none otherwise.
    private func updateMenuBar(phase: FocusPhase?, session: FocusSession?) {
        menuBarTimer?.invalidate(); menuBarTimer = nil
        guard let session, let phase, phase.kind != .ended else { onMenuBarText?(nil); return }
        let now = Date(), text: String, next: TimeInterval
        if let end = phase.endsAt {
            let left = max(0, end.timeIntervalSince(now)), minutes = max(1, Int((left / 60).rounded(.up)))
            text = (phase.isWork ? "" : "Pause ") + "\(minutes) min"
            next = left - Double(minutes - 1) * 60
        } else {
            let elapsed = max(0, now.timeIntervalSince(session.startedAt))
            text = "+\(Int(elapsed / 60)) min"
            next = 60 - elapsed.truncatingRemainder(dividingBy: 60)
        }
        onMenuBarText?(text)
        let timer = Timer(timeInterval: max(1, next + 0.05), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.updateMenuBar(phase: self?.controller?.phase, session: self?.controller?.currentSession) }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuBarTimer = timer
    }
    func deleteData() throws {
        controller?.refresh()
        if controller?.hasLockedBlock == true { error = FocusFailure.locked.rawValue; throw FocusFailure.locked }
        let wasEnabled = modules?.isEnabled(.concentration) == true
        apply(enabled: false)
        do { try storeFactory().deleteData() } catch { self.error = String(describing: error); if wasEnabled { apply(enabled: true) }; throw error }
        if wasEnabled { apply(enabled: true) }
    }
    private func refreshMeasurements() {
        guard measurementTask == nil, let controller else { return }
        let canRead = GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory) && !GoalongGlobalPause.isPaused()
        let store = storeFactory(), calendar = self.calendar, now = clock()
        let verdicts = GoalongWorkStore.shared.verdicts, hasDefinition = !GoalongWorkStore.shared.definition.isEmpty
        let generation = measurementGeneration
        measurementTask = Task { [weak self, weak controller] in
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = calendar.timeZone
            var measured: [String: GoalongLocalAnalytics.Day] = [:]
            do {
                let week = FocusCalendar.weekInterval(now, calendar: calendar).start
                var dates: [Date] = []
                for n in 0...6 { if let d = calendar.date(byAdding: .day, value: n, to: week), d <= now { dates.append(d) } }
                for value in controller?.commitments ?? [] where value.result == nil {
                    guard let bounds = value.period.interval(calendar: calendar) else { continue }
                    var day = bounds.start
                    while day < min(now, bounds.end) {
                        if !dates.contains(day) { dates.append(day) }
                        day = calendar.date(byAdding: .day, value: 1, to: day)!
                    }
                }
                if let current = controller?.currentSession {
                    var day = calendar.startOfDay(for: current.startedAt)
                    while day < now, dates.count < 4096 {
                        if !dates.contains(day) { dates.append(day) }
                        day = calendar.date(byAdding: .day, value: 1, to: day)!
                    }
                }
                for date in dates where canRead {
                    try Task.checkCancellation()
                    measured[BlockingController.dayKey(date, calendar: calendar)] = try await GoalongAnalyticsReader.shared.focusDay(date, verdicts: verdicts)
                }
                var valued = 0
                for day in try store.planDays().reversed() {
                    try Task.checkCancellation()
                    if !canRead { break }
                    guard let plan = try store.plan(day), plan.items.contains(where: { $0.estimateMinutes != nil }), let date = f.date(from: day) else { continue }
                    let value: GoalongLocalAnalytics.Day
                    if let cached = measured[day] { value = cached }
                    else { value = try await GoalongAnalyticsReader.shared.focusDay(date, verdicts: verdicts); measured[day] = value }
                    let sessions = try store.sessions(day)
                    valued += plan.items.filter { $0.estimateMinutes != nil && FocusMeasurement.item($0, sessions: sessions, day: value, now: now).measuredMinutes != nil }.count
                    if valued >= 20 { break }
                }
                guard let self, !Task.isCancelled, generation == self.measurementGeneration,
                      canRead == (GoalongCapabilityConsentStore.shared.isEnabled(.localComputerHistory) && !GoalongGlobalPause.isPaused()) else { if self?.measurementGeneration == generation { self?.measurementTask = nil }; return }
                controller?.applyMeasurements(Array(measured.values), hasDefinition: hasDefinition)
            } catch {
                if !(error is CancellationError) { self?.error = String(describing: error) }
            }
            if self?.measurementGeneration == generation { self?.measurementTask = nil }
        }
    }

    func handle(_ request: GoalongFocusRequest) throws -> Data {
        if request.command == "block-lists" || request.command == "friction" {
            guard modules?.isEnabled(.blocking) == true, let b = blockingProvider() else { throw GoalongFocusError.moduleDisabled }
            let validated = try request.validated()
            if validated.command == "block-lists" {
                let lists: [[String: Any]] = b.lists.map { list in ["id": list.id.uuidString, "name": list.name, "mode": list.mode.rawValue,
                    "action": list.effectiveAction.rawValue, "locked": b.activeBlocks.contains { $0.lock == .locked && $0.listIDs.contains(list.id) } || list.program.isLocked(at: Date())] }
                return try JSONSerialization.data(withJSONObject: ["schema": 1, "lists": lists], options: [.sortedKeys])
            }
            return try FocusJSON.encode(b.frictionCounts(day: resolveDay(validated.options["--day"] ?? "today")))
        }
        guard modules?.isEnabled(.concentration) == true else { throw GoalongFocusError.moduleDisabled }
        guard let controller else { throw GoalongFocusError.storageFailed }
        let request = try request.validated()
        if request.command.hasPrefix("commitment") {
            do { controller.refresh(); return try handleCommitment(request, controller: controller) }
            catch let error as FocusFailure { throw GoalongFocusError(rawValue: error.rawValue) ?? .invalidArgument }
            catch let error as GoalongFocusError { throw error }
            catch { throw GoalongFocusError.invalidArgument }
        }
        let o = request.options, day = try resolveDay(o["--day"] ?? "today")
        do {
            switch request.command {
            case "focus status": return try FocusJSON.encode(controller.status)
            case "session current": return try FocusJSON.encode(CurrentSession(session: controller.currentSession, phase: controller.phase.map { .init(kind: $0.kind.rawValue, cycle: $0.cycle, endsAt: $0.endsAt) }, facts: controller.sessionFacts))
            case "sessions":
                let values = try controller.sessions(on: day).map { session -> [String: Any] in
                    var object = try JSONSerialization.jsonObject(with: FocusJSON.encode(session)) as! [String: Any]
                    object["facts"] = try JSONSerialization.jsonObject(with: FocusJSON.encode(controller.facts(for: session)))
                    return object
                }
                return try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            case "session start":
                var mode = FocusMode()
                if let p = o["--pomodoro"] {
                    let n = p.split(separator: "/").compactMap { Int($0) }; mode.kind = .pomodoro; mode.minutes = nil
                    mode.workMinutes = n[0]; mode.shortBreakMinutes = n[1]; mode.longBreakMinutes = n[2]; mode.longBreakEvery = n[3]; mode.cycles = o["--cycles"].flatMap(Int.init)
                } else { mode.minutes = o["--minutes"].flatMap(Int.init) }
                try controller.startSession(intent: o["--intent"]!, mode: mode, planItemId: o["--plan-item"].flatMap(UUID.init(uuidString:)),
                    blockListIds: o["--block"]?.split(separator: ",").compactMap { UUID(uuidString: String($0)) } ?? [],
                    blockDuringBreaks: request.flags.contains("--block-during-breaks"), lock: request.flags.contains("--lock"), ambiance: request.flags.contains("--ambiance"))
                return try FocusJSON.encode(controller.currentSession)
            case "session skip": try controller.skipPhase(); return try FocusJSON.encode(controller.status)
            case "session stop": try controller.stopSession(outcome: o["--outcome"].flatMap(FocusSession.Outcome.init(rawValue:)), note: o["--note"]); return try FocusJSON.encode(controller.status)
            case "plan show": return try planPayload(controller.plan(on: day), controller: controller)
            case "plan add": _ = try controller.addPlanItem(title: o["title"]!, day: day, project: o["--project"], estimateMinutes: o["--estimate"].flatMap(Int.init))
            case "plan done", "plan drop": try controller.setItemStatus(UUID(uuidString: o["id"]!)!, day: day, status: request.command == "plan done" ? .done : .dropped)
            case "plan move": try controller.movePlanItem(UUID(uuidString: o["id"]!)!, day: day, to: resolveDay(o["--to"]!))
            case "plan set":
                let data = try inputWithIDs(request.body!, day: day, plan: true)
                let value = try FocusJSON.decode(FocusPlan.self, from: data); guard value.day == day else { throw FocusFailure.invalidArgument }; try controller.setPlan(value)
            case "review show": return try reviewPayload(controller.review(on: day), controller: controller)
            case "review set":
                let value = try FocusJSON.decode(FocusReview.self, from: inputWithIDs(request.body!, day: day, plan: false)); guard value.day == day else { throw FocusFailure.invalidArgument }
                try controller.setReview(value); return try reviewPayload(controller.review(on: day), controller: controller)
            case "limits": return try FocusJSON.encode(LimitsEnvelope(limits: controller.settings.limits, marks: controller.limitMarks))
            default: throw FocusFailure.invalidArgument
            }
            return try planPayload(controller.plan(on: day), controller: controller)
        } catch let error as FocusFailure { throw GoalongFocusError(rawValue: error.rawValue) ?? .invalidArgument }
        catch { throw GoalongFocusError.invalidArgument }
    }
    private func planPayload(_ plan: FocusPlan, controller: ConcentrationController) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: FocusJSON.encode(plan)) as! [String: Any]
        object["measures"] = try JSONSerialization.jsonObject(with: FocusJSON.encode(controller.measures(for: plan)))
        object["estimateRatio"] = controller.estimateRatio.map { $0 as Any } ?? NSNull()
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func reviewPayload(_ review: FocusReview, controller: ConcentrationController) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: FocusJSON.encode(review)) as! [String: Any]
        object["measures"] = try JSONSerialization.jsonObject(with: FocusJSON.encode(controller.measures(for: controller.plan(on: review.day))))
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private struct CurrentSession: Encodable {
        struct Phase: Encodable { var kind: String; var cycle: Int; var endsAt: Date? }
        var session: FocusSession?; var phase: Phase?; var facts: FocusFacts
    }
    private struct LimitsEnvelope: Encodable { var limits: FocusLimits; var marks: [FocusLimitMark] }
    private func resolveDay(_ input: String) throws -> String {
        if input == "today" { return FocusCalendar.dayKey(clock(), calendar: calendar) }
        if input == "yesterday" || input == "tomorrow" { return FocusCalendar.dayKey(calendar.date(byAdding: .day, value: input == "tomorrow" ? 1 : -1, to: clock())!, calendar: calendar) }
        guard FocusValidation.day(input) else { throw GoalongFocusError.invalidArgument }; return input
    }
    private func inputWithIDs(_ data: Data, day: String, plan: Bool) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any], var items = object["items"] as? [[String: Any]], items.count <= 10 else { throw GoalongFocusError.invalidArgument }
        object["schema"] = object["schema"] ?? 1; object["day"] = object["day"] ?? day
        for i in items.indices {
            if items[i]["id"] == nil {
                if plan { items[i]["id"] = UUID().uuidString }
                else {
                    let current = try controller?.plan(on: day).items ?? []
                    guard i < current.count else { throw GoalongFocusError.invalidArgument }
                    items[i]["id"] = current[i].id.uuidString
                }
            }
            if plan { items[i]["status"] = items[i]["status"] ?? "open" }
        }
        object["items"] = items
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func resolveWeek(_ input: String) throws -> String {
        if input == "this" { return FocusCalendar.weekKey(clock(), calendar: calendar) }
        if input == "next" { return FocusCalendar.weekKey(FocusCalendar.weekInterval(clock(), calendar: calendar).end, calendar: calendar) }
        guard FocusCalendar.weekInterval(input, calendar: calendar) != nil else { throw FocusFailure.invalidArgument }; return input
    }
    private func selectedPeriod(_ options: [String: String]) throws -> FocusCommitmentPeriod {
        if let day = options["--day"] { return .init(kind: .day, key: try resolveDay(day)) }
        guard let week = options["--week"] else { throw FocusFailure.invalidArgument }
        return .init(kind: .week, key: try resolveWeek(week))
    }
    private func commitmentObject(_ period: FocusCommitmentPeriod, controller: ConcentrationController) throws -> Any {
        guard let card = controller.commitmentCards.first(where: { $0.commitment.period == period }) else { return NSNull() }
        var object = try JSONSerialization.jsonObject(with: FocusJSON.encode(card.commitment)) as! [String: Any]
        object["progress"] = try JSONSerialization.jsonObject(with: FocusJSON.encode(card.progress))
        object["series"] = card.series; object["jokersLeft"] = card.jokersLeft
        object["canUseJoker"] = card.canUseJoker; object["canDeclare"] = card.canDeclare
        object["exitUntil"] = try JSONSerialization.jsonObject(with: FocusJSON.encode(card.exitUntil), options: [.fragmentsAllowed])
        object["limitHours"] = card.limitHours.map { $0 as Any } ?? NSNull()
        object["editMode"] = card.editMode
        object["editUntil"] = try JSONSerialization.jsonObject(with: FocusJSON.encode(card.editUntil), options: [.fragmentsAllowed])
        return object
    }
    private struct CommitmentInput: Decodable {
        var period: FocusCommitmentPeriod?
        var kind: FocusCommitment.Kind
        var target: Int
        var task: String?
        var stake: FocusStake?
    }
    private func handleCommitment(_ request: GoalongFocusRequest, controller: ConcentrationController) throws -> Data {
        let o = request.options
        if request.command == "commitments" {
            let lower = o["--from"].flatMap { FocusCalendar.dayInterval($0, calendar: calendar)?.start } ?? .distantPast
            let upper = o["--to"].flatMap { FocusCalendar.dayInterval($0, calendar: calendar)?.end } ?? .distantFuture
            let history = try controller.commitments.filter { value in
                let bounds = value.period.interval(calendar: calendar)!
                return bounds.start < upper && bounds.end > lower
            }.sorted { $0.period.key < $1.period.key }.map { try commitmentObject($0.period, controller: controller) }
            return try JSONSerialization.data(withJSONObject: ["schema": 1, "commitments": history,
                "series": try JSONSerialization.jsonObject(with: FocusJSON.encode(controller.commitmentSeries)),
                "jokersLeft": try JSONSerialization.jsonObject(with: FocusJSON.encode(controller.commitmentJokersLeft)),
                "jokerSettings": try JSONSerialization.jsonObject(with: FocusJSON.encode(controller.settings.jokerSettings))], options: [.sortedKeys])
        }
        if request.command == "commitment show", o.count != 1 {
            let day = FocusCommitmentPeriod(kind: .day, key: try resolveDay(o["--day"] ?? "today"))
            let week = FocusCommitmentPeriod(kind: .week, key: try resolveWeek(o["--week"] ?? "this"))
            return try JSONSerialization.data(withJSONObject: ["schema": 1, "day": try commitmentObject(day, controller: controller),
                "week": try commitmentObject(week, controller: controller)], options: [.sortedKeys])
        }
        let period = try selectedPeriod(o)
        switch request.command {
        case "commitment show": break
        case "commitment set":
            if let body = request.body {
                let input = try FocusJSON.decode(CommitmentInput.self, from: body)
                guard input.period == nil || input.period == period else { throw FocusFailure.invalidArgument }
                _ = try controller.setCommitment(period: period, kind: input.kind, target: input.target, task: input.task, stake: input.stake)
            } else {
                guard let kind = o["--kind"].flatMap(FocusCommitment.Kind.init(rawValue:)),
                      let target = GoalongCommitmentCLI.target(o["--target"] ?? "", kind: kind.rawValue) else { throw FocusFailure.invalidArgument }
                let stake = o["--stake"].map { FocusStake(listIds: $0.split(separator: ",").compactMap { UUID(uuidString: String($0)) }, until: o["--until"] ?? "12:00") }
                _ = try controller.setCommitment(period: period, kind: kind, target: target, task: o["--task"], stake: stake)
            }
        case "commitment delete":
            try controller.deleteCommitment(period: period)
            return try JSONSerialization.data(withJSONObject: ["schema": 1, "deleted": true, "period": try JSONSerialization.jsonObject(with: FocusJSON.encode(period))], options: [.sortedKeys])
        case "commitment joker": try controller.useCommitmentJoker(period: period)
        case "commitment declare": try controller.declareCommitmentHeld(period: period)
        default: throw FocusFailure.invalidArgument
        }
        return try JSONSerialization.data(withJSONObject: commitmentObject(period, controller: controller), options: [.sortedKeys, .fragmentsAllowed])
    }
}
#endif
