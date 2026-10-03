#if os(macOS)
import Foundation
import LocalHistoryCore

/// All defaults are off. Reviewing earlier computer/conversation choices never enables a new lane.
struct GoalongSystemRecapSelection: Codable, Equatable {
    var calls = false
    var calendar = false
    var otherDevices = false
    var health = false
    var dayNote = false
    var hasSources: Bool { calls || calendar || otherDevices || health || dayNote }
}
private final class GoalongCalendarRecapRead: @unchecked Sendable {
    let lock = NSLock()
    var lane = GoalongCalendarLane.disabled
    let completed = DispatchSemaphore(value: 0)
    func finish(_ lane: GoalongCalendarLane) { lock.lock(); self.lane = lane; lock.unlock(); completed.signal() }
    func value() -> GoalongCalendarLane { lock.lock(); defer { lock.unlock() }; return lane }
}
enum GoalongSystemRecapSections {
    /// The existing recap builder is synchronous and runs on a utility worker. Bound its wait;
    /// an accidental main-thread caller gets an explicit partial agenda rather than blocking UI.
    static func load(root: URL, day: GoalongLocalAnalytics.Day, selection: GoalongSystemRecapSelection,
                     consent: GoalongConsentDocument, scope: GoalongAnalysisScope, privacy: GoalongPrivacyPolicy) -> GoalongSystemSourcesDay {
        let config = try? RecorderConfig.load(from: root.appendingPathComponent("config.json"))
        let calls = GoalongCallPresenceMonitor.lane(root: root, day: day.date,
            enabled: selection.calls && consent.isEnabled(.localComputerHistory) && config?.effectiveCaptureCallPresence != false, privacy: privacy)
        var agenda = GoalongCalendarLane.disabled
        if selection.calendar && consent.isEnabled(.calendar) && !privacy.hasExclusions {
            if Thread.isMainThread { agenda = .init(status: .partial, calendarStatus: .partial, remindersStatus: .partial) }
            else {
                let result = GoalongCalendarRecapRead()
                let task = Task { result.finish(await GoalongCalendarSource.shared.read(day: day.date, enabled: true)) }
                if result.completed.wait(timeout: .now() + 9) == .success { agenda = result.value() }
                else { task.cancel(); agenda = .init(status: .partial, calendarStatus: .partial, remindersStatus: .partial) }
            }
        }
        let health = selection.health && !privacy.blocked ? GoalongHealthSource.load(root: root, day: day.date) : GoalongHealthLane(status: .disabled)
        let otherDevices = GoalongOtherDevicesSource.load(root: root, day: day, enabled: selection.otherDevices && consent.isEnabled(.appleScreenTime), deviceIDs: scope.deviceIDs.map(Set.init), privacy: privacy, allowsApplication: { app in
            if !privacy.domains.isEmpty || !scope.excludedDomains.isEmpty {
                if RecorderConfig.default.browserBundleIdentifiers.contains(app.bundleIdentifier ?? app.id) { return false }
            }
            return scope.allows(id: app.bundleIdentifier ?? app.id, name: app.resolvedName)
        })
        let note: String?, noteStatus: GoalongSystemSourceStatus
        do {
            note = selection.dayNote && !privacy.hasExclusions ? try GoalongDayNoteStore.get(root: root, day: day.date) : nil
            noteStatus = !selection.dayNote ? .disabled : note == nil ? .noData : .ready
        } catch { note = nil; noteStatus = .failed("Note du jour illisible.") }
        return .init(calls: calls, calendar: agenda, otherDevices: otherDevices, health: health, note: note, noteStatus: noteStatus)
    }
    static func append(_ sources: GoalongSystemSourcesDay, selection: GoalongSystemRecapSelection,
                       scope: GoalongAnalysisScope, privacy: GoalongPrivacyPolicy,
                       text: (String, Int) throws -> String, to document: inout [String: Any]) throws -> Int {
        guard !privacy.blocked else { return 0 }
        func status(_ value: GoalongSystemSourceStatus) -> String {
            switch value {
            case .disabled: return "disabled"
            case .permissionDenied: return "permissionDenied"
            case .unsupported: return "unsupported"
            case .noData: return "noData"
            case .partial: return "partial"
            case .ready: return "ready"
            case .failed: return "failed"
            }
        }
        var items = 0
        if selection.calls {
            let browsers = Set(RecorderConfig.default.browserBundleIdentifiers.map { $0.lowercased() })
            let rows = sources.calls.intervals.filter { interval in
                guard let name = interval.application, scope.allows(id: interval.bundleIdentifier, name: name),
                      !privacy.excludes(appID: interval.bundleIdentifier, name: name) else { return false }
                if !privacy.domains.isEmpty || !scope.excludedDomains.isEmpty { return !browsers.contains(interval.bundleIdentifier?.lowercased() ?? "") }
                return true
            }
            let values: [[String: Any]] = try rows.prefix(64).map { row in
                ["application": try text(row.application ?? "", 256), "debut": row.start.timeIntervalSince1970,
                 "fin": row.end.timeIntervalSince1970, "microphone": row.microphone, "camera": row.camera]
            }
            document["usages_micro_camera"] = ["statut": status(sources.calls.status), "intervalles": values,
                "partiel": rows.count > 64 || rows.count != sources.calls.intervals.count,
                "lecture": "Usages détectés, pas une preuve de réunion ni du contenu sonore ou vidéo."]
            items += values.count
        }
        if selection.calendar {
            // EventKit titles have no app/domain provenance. Preserve the global exclusion boundary.
            if privacy.hasExclusions { document["agenda_rappels"] = ["statut": "partial", "lecture": "Sources sans provenance exclues par le filtre de confidentialité."] }
            else {
                let rows: [[String: Any]] = try sources.calendar.events.prefix(64).map { row in
                    ["debut": row.start.timeIntervalSince1970, "fin": row.end.timeIntervalSince1970, "jour_entier": row.allDay,
                     "disponibilite": row.availability, "titre": try text(row.title, 280),
                     "calendrier": try text(row.calendarName, 160), "participants": row.attendeeCount]
                }
                let reminders: [[String: Any]] = try sources.calendar.completedReminders.prefix(64).map {
                    ["termine_le": $0.completedAt.timeIntervalSince1970, "titre": try text($0.title, 280)]
                }
                document["agenda_rappels"] = ["statut": status(sources.calendar.status), "agenda_statut": status(sources.calendar.calendarStatus),
                    "rappels_statut": status(sources.calendar.remindersStatus), "secondes_prevues_occupees": sources.calendar.plannedBusySeconds,
                    "evenements": rows, "rappels_termines": reminders, "rappels_echus_ouverts": sources.calendar.openDueReminderCount,
                    "partiel": sources.calendar.events.count > 64 || sources.calendar.completedReminders.count > 64]
                items += rows.count + reminders.count + sources.calendar.openDueReminderCount
            }
        }
        if selection.otherDevices {
            let rows: [[String: Any]] = sources.otherDevices.devices.prefix(32).enumerated().map { index, row in
                ["appareil": "Appareil \(index + 1)", "secondes_ecran_allume": row.screenOnSeconds,
                 "secondes_pendant_lacunes_Mac": row.duringMacGapsSeconds, "secondes_pendant_activite_Mac": row.duringMacActivitySeconds,
                 "estime": row.estimated, "actualise_le": row.lastUpdatedAt.timeIntervalSince1970]
            }
            document["autres_appareils"] = ["statut": status(sources.otherDevices.status), "appareils": rows,
                "lecture": "Chevauchements descriptifs, jamais ajoutés au temps actif du Mac."]
            items += rows.count
        }
        if selection.health {
            var row: [String: Any] = ["statut": status(sources.health.status), "lecture_sommeil": sources.health.sleepLabel,
                                     "entrainements": sources.health.workoutCount, "secondes_entrainements": sources.health.workoutSeconds]
            if let seconds = sources.health.sleepSeconds { row["secondes_sommeil"] = seconds; row["phases_sommeil"] = sources.health.sleepStages; items += 1 }
            if let steps = sources.health.steps { row["pas"] = steps; items += 1 }
            if let zone = sources.health.timeZone { row["fuseau_import"] = try text(zone, 100) }
            items += sources.health.workoutCount; document["contexte_sante_importe"] = row
        }
        if selection.dayNote {
            var row: [String: Any] = ["statut": status(sources.noteStatus)]
            if let note = sources.note, !privacy.hasExclusions { row["texte"] = try text(note, 280); items += 1 }
            document["note_du_jour"] = row
        }
        return items
    }
}
#endif
