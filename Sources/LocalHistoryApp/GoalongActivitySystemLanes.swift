#if os(macOS)
import Foundation
import SwiftUI
import LocalHistoryCore

// MARK: - Appels et agenda

/// « Appels et agenda » for one day: what was planned, and when the microphone or camera ran.
struct GoalongAgendaDay: Equatable {
    struct Event: Identifiable, Equatable {
        let id: String
        let start: Date
        let end: Date
        let title: String
        var attendees = 0
        /// Observed calls during this event.
        var callSeconds: TimeInterval = 0
        var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
    }
    struct Share: Identifiable, Equatable {
        let id: String
        let seconds: TimeInterval
    }
    struct Reminder: Identifiable, Equatable {
        let id: String
        let completedAt: Date
        let title: String
    }

    /// Planned busy events (not all-day, not « disponible »).
    var events: [Event] = []
    var calls: [DateInterval] = []
    var callApplications: [Share] = []
    var reminders: [Reminder] = []
    var openDueReminders = 0
    var callsOn = false
    var calendarOn = false
    /// macOS access to the agenda and reminders, once « Agenda et rappels » is on.
    enum CalendarAccess { case granted, notAsked, denied }
    var calendarAccess = CalendarAccess.granted
    var partial = false

    var plannedSeconds: TimeInterval { GoalongIntervals.merged(events.map(\.interval)).reduce(0) { $0 + $1.duration } }
    var callSeconds: TimeInterval { GoalongIntervals.merged(calls).reduce(0) { $0 + $1.duration } }
    /// Calls outside every planned event.
    var unplannedCallSeconds: TimeInterval { GoalongIntervals.seconds(calls, outside: events.map(\.interval)) }
    var isEmpty: Bool { events.isEmpty && calls.isEmpty && reminders.isEmpty && openDueReminders == 0 }

    var caption: String {
        var parts: [String] = []
        if callSeconds >= 60 { parts.append("\(GoalongAnalyticsFormatting.duration(callSeconds)) d’appels") }
        if plannedSeconds >= 60 { parts.append("\(GoalongAnalyticsFormatting.duration(plannedSeconds)) prévues") }
        if !reminders.isEmpty { parts.append(GoalongCodeDay.count(reminders.count, "rappel terminé", "rappels terminés")) }
        if parts.isEmpty { return calendarOn && calendarAccess != .granted ? "Accès à l’agenda à autoriser" : "Aucun appel ni événement prévu" }
        return parts.joined(separator: " · ")
    }
}

struct GoalongAgendaSection: View {
    let agenda: GoalongAgendaDay
    let day: GoalongLocalAnalytics.Day
    var isPreview = false
    var onSettings: () -> Void = {}
    var onAllowCalendar: () -> Void = {}

    var body: some View {
        GoalongSection(title: "Appels et agenda", subtitle: lead) {
            VStack(alignment: .leading, spacing: 22) {
                if !agenda.events.isEmpty || !agenda.calls.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        GoalongLaneLegend(items: legend)
                        GoalongLaneMatrix(rows: rows, range: range, summary: agenda.caption)
                    }
                }
                if !agenda.events.isEmpty { eventList }
                if !agenda.callApplications.isEmpty { callList }
                if !agenda.reminders.isEmpty || agenda.openDueReminders > 0 { reminderList }
                ForEach(notes, id: \.text) { note in
                    HStack(alignment: .center, spacing: 12) {
                        GoalongNote(note.text)
                        Button(note.action, action: note.perform).buttonStyle(LHQuietButtonStyle()).font(.system(size: 13))
                            .disabled(isPreview)
                    }
                }
                Text("Un appel compte quand le micro ou la caméra sert à une app : ce n’est pas une preuve de réunion, et aucun son ni image n’est lu. Les titres de l’agenda sont lus à l’affichage et jamais enregistrés. Rien de tout cela ne s’ajoute au temps actif.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("activity-agenda")
    }

    private var lead: String {
        var sentences: [String] = []
        let planned = agenda.plannedSeconds, calls = agenda.callSeconds
        if agenda.calendarOn && agenda.callsOn && (planned >= 60 || calls >= 60) {
            var text = "\(GoalongAnalyticsFormatting.duration(planned)) prévues dans l’agenda, \(GoalongAnalyticsFormatting.duration(calls)) d’appels observés"
            let unplanned = agenda.unplannedCallSeconds
            if planned >= 60 && unplanned >= 60 { text += ", dont \(GoalongAnalyticsFormatting.duration(unplanned)) hors agenda" }
            sentences.append(text + ".")
        } else if calls >= 60 {
            sentences.append("\(GoalongAnalyticsFormatting.duration(calls)) d’appels observés.")
        } else if planned >= 60 {
            sentences.append("\(GoalongAnalyticsFormatting.duration(planned)) prévues dans l’agenda.")
        }
        if !agenda.reminders.isEmpty {
            sentences.append(GoalongCodeDay.count(agenda.reminders.count, "rappel terminé.", "rappels terminés."))
        }
        return sentences.isEmpty ? "Aucun appel ni événement prévu ce jour-là." : sentences.joined(separator: " ")
    }

    private var legend: [(mark: GoalongLaneMark, title: String)] {
        var items: [(mark: GoalongLaneMark, title: String)] = []
        if !agenda.events.isEmpty { items.append((.outlined, "Événement prévu")) }
        if !agenda.calls.isEmpty { items.append((.solid, "Appel : micro ou caméra en cours")) }
        return items
    }

    private var rows: [GoalongLaneMatrix.Row] {
        var rows: [GoalongLaneMatrix.Row] = []
        if day.segments.contains(where: { $0.kind.isActive }) { rows.append(.init(id: "you", label: "Vous", segments: day.segments)) }
        if agenda.calendarOn { rows.append(.init(id: "agenda", label: "Agenda", outlined: agenda.events.map(\.interval))) }
        if agenda.callsOn { rows.append(.init(id: "calls", label: "Appels", solid: agenda.calls)) }
        return rows
    }

    private var range: ClosedRange<Date> {
        GoalongLaneMatrix.range(day: day, marks: agenda.events.flatMap { [$0.start, $0.end] } + agenda.calls.flatMap { [$0.start, $0.end] })
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prévu").font(.system(size: 13, weight: .semibold))
            VStack(spacing: 0) {
                ForEach(Array(agenda.events.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Divider().padding(.leading, 6) }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(GoalongSummaryFormat.time(event.start)) – \(GoalongSummaryFormat.time(event.end))")
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(LHTheme.secondaryText)
                            .frame(width: 96, alignment: .leading)
                        Text(event.title.isEmpty ? "Sans titre" : event.title).font(.system(size: 13)).lineLimit(1)
                        if event.attendees > 1 {
                            Text(GoalongCodeDay.count(event.attendees, "participant", "participants"))
                                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if agenda.callsOn {
                            Text(event.callSeconds >= 60 ? "appel \(GoalongAnalyticsFormatting.duration(event.callSeconds))" : "aucun appel")
                                .font(.system(size: 12)).monospacedDigit()
                                .foregroundStyle(event.callSeconds >= 60 ? LHTheme.text : LHTheme.tertiaryText)
                        }
                    }
                    .padding(.vertical, 7).padding(.horizontal, 6)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var callList: some View {
        let total = max(1, agenda.callApplications.reduce(0) { $0 + $1.seconds })
        return VStack(alignment: .leading, spacing: 10) {
            Text("Appels par app").font(.system(size: 13, weight: .semibold))
            ForEach(agenda.callApplications) { share in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(share.id).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(GoalongAnalyticsFormatting.duration(share.seconds)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    }
                    GoalongShareBar(share: share.seconds / total, color: LHTheme.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var reminderList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rappels").font(.system(size: 13, weight: .semibold))
            ForEach(agenda.reminders) { reminder in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(GoalongSummaryFormat.time(reminder.completedAt)).font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(LHTheme.secondaryText).frame(width: 96, alignment: .leading)
                    Text(reminder.title.isEmpty ? "Sans titre" : reminder.title).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .accessibilityElement(children: .combine)
            }
            if agenda.openDueReminders > 0 {
                Text(GoalongCodeDay.count(agenda.openDueReminders, "rappel prévu ce jour-là reste ouvert.", "rappels prévus ce jour-là restent ouverts."))
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).padding(.horizontal, 6)
            }
        }
    }

    private var notes: [(text: String, action: String, perform: () -> Void)] {
        var notes: [(text: String, action: String, perform: () -> Void)] = []
        if !agenda.callsOn {
            notes.append(("Pour voir vos appels, activez « Appels » dans Réglages › Enregistrement.", "Réglages…", onSettings))
        }
        if !agenda.calendarOn {
            notes.append(("Pour comparer avec ce qui était prévu, activez « Agenda et rappels ».", "Réglages…", onSettings))
        } else if agenda.calendarAccess == .notAsked {
            notes.append(("macOS n’a pas encore donné l’accès à l’agenda et aux rappels.", "Autoriser…", onAllowCalendar))
        } else if agenda.calendarAccess == .denied {
            notes.append(("macOS refuse l’accès à l’agenda ou aux rappels. Vous pouvez le donner dans Réglages Système.", "Ouvrir…", onAllowCalendar))
        }
        return notes
    }
}

// MARK: - Sommeil et activité

/// « Sommeil et activité »: an Apple Health import for this date, beside the Mac's day.
struct GoalongSleepDay: Equatable {
    var sleepSeconds: TimeInterval?
    var stages: [GoalongAgendaDay.Share] = []
    var steps: Int?
    var workouts = 0
    var workoutSeconds: TimeInterval = 0
    var label = ""
    var partial = false

    var caption: String {
        var parts: [String] = []
        if let sleepSeconds, sleepSeconds >= 60 { parts.append("\(GoalongAnalyticsFormatting.duration(sleepSeconds)) de sommeil") }
        if let steps, steps > 0 { parts.append(GoalongCodeDay.count(steps, "pas", "pas")) }
        if workouts > 0 { parts.append(GoalongCodeDay.count(workouts, "séance", "séances")) }
        return parts.isEmpty ? "Import Santé sans mesure pour cette date" : parts.joined(separator: " · ")
    }
}

struct GoalongSleepSection: View {
    let sleep: GoalongSleepDay

    var body: some View {
        GoalongSection(title: "Sommeil et activité", subtitle: lead) {
            VStack(alignment: .leading, spacing: 16) {
                let total = max(1, sleep.stages.reduce(0) { $0 + $1.seconds })
                ForEach(sleep.stages) { stage in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(stage.id).font(.system(size: 13)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(GoalongAnalyticsFormatting.duration(stage.seconds)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        }
                        GoalongShareBar(share: stage.seconds / total, color: LHTheme.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("\(sleep.label). Données importées depuis Apple Santé : Goalong ne lit pas Santé en continu, et ce sommeil ne compte pas dans le temps actif.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("activity-sleep")
    }

    private var lead: String {
        var parts: [String] = []
        if let seconds = sleep.sleepSeconds, seconds >= 60 { parts.append("\(GoalongAnalyticsFormatting.duration(seconds)) de sommeil") }
        if let steps = sleep.steps, steps > 0 { parts.append(GoalongCodeDay.count(steps, "pas", "pas")) }
        if sleep.workouts > 0 {
            parts.append(GoalongCodeDay.count(sleep.workouts, "séance d’entraînement", "séances d’entraînement")
                + (sleep.workoutSeconds >= 60 ? " (\(GoalongAnalyticsFormatting.duration(sleep.workoutSeconds)))" : ""))
        }
        guard !parts.isEmpty else { return "L’import Santé ne contient aucune mesure pour cette date." }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " et " + parts[parts.count - 1] : parts[0]
        return list.prefix(1).uppercased() + list.dropFirst() + (sleep.partial ? ". Import partiel." : ".")
    }
}

// MARK: - Pendant les trous du Mac

/// Other Apple devices while the Mac was idle or unobserved, from the Screen Time archive.
struct GoalongOtherDevicesDay: Equatable {
    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
        let screenOnSeconds: TimeInterval
        let duringGapsSeconds: TimeInterval
        let estimated: Bool
    }
    var devices: [Device] = []
    var partial = false

    var duringGapsSeconds: TimeInterval { devices.reduce(0) { $0 + $1.duringGapsSeconds } }
}

struct GoalongOtherDevicesSection: View {
    let value: GoalongOtherDevicesDay

    var body: some View {
        GoalongSection(title: "Pendant les trous du Mac", subtitle: lead) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 0) {
                    ForEach(Array(value.devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { Divider().padding(.leading, 6) }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text("\(GoalongAnalyticsFormatting.duration(device.screenOnSeconds)) d’écran en tout")
                                .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(GoalongAnalyticsFormatting.duration(device.duringGapsSeconds) + (device.estimated ? " env." : ""))
                                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        }
                        .padding(.vertical, 9).padding(.horizontal, 6)
                        .accessibilityElement(children: .combine)
                    }
                }
                Text("Écran allumé ne veut pas dire utilisé. Temps d’écran Apple compte par heure : quand une heure chevauche un trou du Mac, sa part est estimée. Ces durées ne s’ajoutent jamais au temps du Mac.")
                    .font(.system(size: 12)).foregroundStyle(LHTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("activity-other-devices")
    }

    private var lead: String {
        let seconds = value.duringGapsSeconds
        guard seconds >= 60 else { return "Aucun autre appareil allumé pendant les trous du Mac." }
        let estimated = value.devices.contains { $0.estimated } ? ", en partie estimé" : ""
        return "Quand le Mac était inactif ou sans observation, vos autres appareils ont eu l’écran allumé \(GoalongAnalyticsFormatting.duration(seconds))\(estimated)."
    }
}

// MARK: - Note du jour

/// « Note du jour » on the summary: the note, or a quiet way to write one.
struct GoalongDayNoteBlock: View {
    let note: String?
    var isPreview = false
    var onEdit: () -> Void = {}

    var body: some View {
        if let note, !note.isEmpty {
            GoalongSection(title: "Note du jour") {
                Button("Modifier", action: onEdit).buttonStyle(LHQuietButtonStyle()).font(.system(size: 13))
                    .disabled(isPreview).accessibilityIdentifier("activity-note-edit")
            } content: {
                Text(note).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .accessibilityIdentifier("activity-note")
        } else {
            Button(action: onEdit) { Label("Ajouter une note sur cette journée", systemImage: "square.and.pencil") }
                .buttonStyle(LHQuietButtonStyle()).font(.system(size: 13))
                .disabled(isPreview).accessibilityIdentifier("activity-note-add")
        }
    }
}

struct GoalongDayNoteSheet: View {
    static let limit = 280
    let day: Date
    let initial: String
    var onSave: (String) throws -> Void
    var onDelete: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var problem: String?

    init(day: Date, initial: String, onSave: @escaping (String) throws -> Void, onDelete: @escaping () throws -> Void) {
        self.day = day; self.initial = initial; self.onSave = onSave; self.onDelete = onDelete
        _text = State(initialValue: initial)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Note du \(GoalongUIFormat.day(day))").font(LHTheme.sheetTitleFont)
            Text("Ce qui a marqué la journée, ou ce que les chiffres ne montrent pas. La note reste sur ce Mac. Elle n’est envoyée que si vous cochez « Note du jour » dans les sources du bilan : elle sert alors au bilan et à l’agent de « Mon travail ».")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GoalongTextArea(text: $text, placeholder: "Par exemple : journée coupée par deux rendez-vous.", minHeight: 96)
                .accessibilityIdentifier("activity-note-text")
            HStack(spacing: 10) {
                Text("\(trimmed.count) / \(Self.limit)").font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(trimmed.count > Self.limit ? LHTheme.warning : LHTheme.tertiaryText)
                if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(LHTheme.warning).lineLimit(2) }
                Spacer(minLength: 8)
                if !initial.isEmpty {
                    Button("Supprimer", role: .destructive) { attempt { try onDelete() } }.buttonStyle(LHQuietButtonStyle())
                }
                Button("Annuler") { dismiss() }.buttonStyle(LHSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Enregistrer") { attempt { try onSave(trimmed) } }.buttonStyle(LHPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || trimmed.count > Self.limit || trimmed == initial)
            }
        }
        .padding(24).frame(width: 480)
    }

    private func attempt(_ change: () throws -> Void) {
        do { try change(); dismiss() } catch { problem = "La note n’a pas pu être enregistrée." }
    }
}
#endif
