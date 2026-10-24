#if os(macOS)
import EventKit
import Foundation
import LocalHistoryCore
import SwiftUI
@testable import LocalHistoryApp

/// Every screen that shows what the calendar and the reminders gave: Activité (the « Appels et agenda » block and its
/// source list) and Réglages › Enregistrement (the access message). The page reads through the app's own code; only
/// the calendar behind it is replaced (`GoalongFakeCalendarBackend`), so no image reads the real calendar or asks for access.
extension GalleryCatalog {
    private enum Agenda { case withData, empty, denied, notAsked }

    private static func event(_ id: String, _ title: String, _ start: Date, _ end: Date, attendees: Int = 0,
                              allDay: Bool = false, free: Bool = false) -> GoalongRawCalendarEvent {
        .init(id: id, start: start, end: end, allDay: allDay,
              availability: (free ? EKEventAvailability.free : .busy).rawValue, title: title,
              calendarName: "Travail", attendeeCount: attendees)
    }
    private static func reminder(_ title: String, done: Date?, due: Date? = nil) -> GoalongRawReminder {
        var parts: DateComponents?
        if let due {
            var components = GalleryClock.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            components.calendar = GalleryClock.calendar; components.timeZone = GalleryClock.timeZone
            parts = components
        }
        return .init(title: title, completionDate: done, isCompleted: done != nil, due: parts)
    }

    /// Installs the fake calendar for the entry and puts the real one back afterwards.
    private static func installCalendar(_ state: Agenda, _ ctx: GalleryContext) -> GoalongFakeCalendarBackend {
        let backend = GoalongFakeCalendarBackend()
        switch state {
        case .withData:
            backend.events = [
                event("equipe", "Point d’équipe", GalleryClock.at(9, 30), GalleryClock.at(9, 45), attendees: 6),
                event("maquettes", "Revue des maquettes Atlas", GalleryClock.at(11), GalleryClock.at(12), attendees: 3),
                event("midi", "Déjeuner avec Camille", GalleryClock.at(12, 30), GalleryClock.at(13, 30), attendees: 1),
                event("libre", "Bloc libre pour écrire", GalleryClock.at(14), GalleryClock.at(15), free: true),
                event("atelier", "Atelier de lancement", GalleryClock.at(16), GalleryClock.at(16, 45), attendees: 4),
                event("fete", "Anniversaire de Léo", GalleryClock.today, GalleryClock.at(0, 0, dayOffset: 1), allDay: true),
            ]
            backend.completed = [
                reminder("Relire les notes de version", done: GalleryClock.at(8, 20)),
                reminder("Envoyer la facture de septembre", done: GalleryClock.at(9, 5)),
            ]
            backend.due = [reminder("Appeler le comptable", done: nil, due: GalleryClock.at(17)),
                           reminder("Réserver le train de lundi", done: nil, due: GalleryClock.at(18, 30))]
        case .empty: break
        case .denied: backend.setPermissions(events: .permissionDenied, reminders: .permissionDenied)
        case .notAsked: backend.setPermissions(events: .noData, reminders: .noData)
        }
        GoalongCalendarBackends.install(backend)
        ctx.cleanups.append { GoalongCalendarBackends.install(nil) }
        GoalongCapabilityConsentStore.shared.set(.calendar, enabled: true, surface: .settings)
        return backend
    }

    private static func agendaActivity(_ id: String, _ state: Agenda, note: String) -> GalleryEntry {
        var backend: GoalongFakeCalendarBackend?
        return dashboard(id, section: .overview, sizes: [.full(1240)], fixture: .classified, note: note,
                         reached: { state == .denied || state == .notAsked || (backend?.enumerations ?? 0) > 0 },
                         prepare: { ctx in backend = installCalendar(state, ctx) })
    }
    private static func agendaSettings(_ id: String, _ state: Agenda, note: String) -> GalleryEntry {
        dashboard(id, section: .settings, pane: .recording, sizes: [.fixed(1240, 1560)], fixture: .recordingOn, note: note,
                  prepare: { ctx in _ = installCalendar(state, ctx) })
    }

    static var agendaEntries: [GalleryEntry] {
        [
            agendaActivity("agenda/jour-avec-donnees", .withData,
                           note: "Activité, jour : quatre événements prévus (un libre, un sur la journée), deux rappels terminés, deux à faire"),
            agendaActivity("agenda/jour-vide", .empty, note: "accès donné, aucun événement ni rappel ce jour-là"),
            agendaActivity("agenda/acces-refuse", .denied, note: "macOS refuse l’agenda et les rappels : message et « Ouvrir… »"),
            agendaSettings("agenda/reglages-acces-refuse", .denied, note: "Réglages › Enregistrement : accès refusé, « Ouvrir Réglages Système… »"),
            agendaSettings("agenda/reglages-acces-non-demande", .notAsked, note: "Réglages › Enregistrement : accès à demander, « Autoriser l’accès… »"),
        ]
    }
}
#endif
