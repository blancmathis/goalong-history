#if os(macOS)
import Foundation
import LocalHistoryCore

/// Deterministic, in-memory fixtures. No recorder, archive, consent, network or file access.
/// Generated from calendar dates so a given day's values match in 1 / 7 / 28-day views.
enum GoalongAnalyticsPreview {
    static func make(ending date: Date, count rawCount: Int, calendar: Calendar = .current,
                     now: Date = Date()) -> GoalongAnalyticsPayload {
        let count = [1, 7, 28].contains(rawCount) ? rawCount : 7
        let last = calendar.startOfDay(for: date)
        let days = (0..<(count * 2)).reversed().compactMap { offset -> GoalongLocalAnalytics.Day? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: last) else { return nil }
            return makeDay(day, calendar: calendar)
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let dayLabel = formatter.string(from: last)
        let examples: [(String, String, String, String)] = [
            ("totals", "Une journée entre création et échanges", "Les mesures fictives illustrent une alternance de longues séquences de création et de tâches plus courtes. Les durées exactes restent dans les graphiques ci-dessus.", "observed"),
            ("apps", "Des outils complémentaires", "L’éditeur sert au développement, Figma à la conception et le navigateur à la documentation. Les sites restent inclus dans le temps du navigateur.", "observed"),
            ("projects", "Parcours mobile · conception et intégration", "Exemple de projet regroupant la conception des écrans, leur intégration et la vérification du parcours. Plusieurs applications peuvent contribuer au même projet.", "inferred"),
            ("projects", "Documentation · préparer la prochaine livraison", "Un second projet illustre la préparation des notes de version et des points à vérifier avant une livraison.", "inferred"),
            ("work", "Concevoir, développer, relire", "La présentation distingue ici la conception d’interface, le développement et la rédaction. Un type de travail ne constitue pas une preuve de résultat.", "inferred"),
            ("rhythm", "Des séquences longues le matin", "Exemple d’interprétation du rythme : une première plage continue de création, puis des échanges et une reprise l’après-midi. Le focus observé ne mesure pas l’attention mentale.", "observed"),
            ("progress", "Prochaine étape · vérifier le parcours complet", "Exemple d’avancée déclarée : les principaux écrans sont intégrés. Prochaine étape suggérée : relire les états vides et tester le parcours sur une petite fenêtre.", "declared"),
            ("methods", "Alterner réalisation et vérification", "Exemple de méthode : construire un écran, le tester, puis documenter la décision avant de passer au suivant.", "inferred"),
            ("evolution", "Deux périodes à mettre en regard", "Exemple de carte d’évolution. Les périodes précédentes sont elles aussi entièrement simulées ; aucune évolution réelle n’est déduite de cet aperçu.", "inferred"),
            ("recap", "Une vue d’ensemble, au-delà des heures", "Exemple de récapitulatif reliant les projets, les outils et les prochaines étapes, sans transformer le temps passé en score de productivité.", "inferred"),
            ("ai", "Une aide ponctuelle à la relecture", "Exemple de rubrique IA : une conversation pourrait éclairer une décision ou une relecture. Aucune conversation personnelle n’a été consultée et aucun agent n’a été lancé.", "declared")
        ]
        let cards = examples.enumerated().map { index, example in
            GoalongAnalyticsCard(id: "preview-\(dayLabel)-\(index)", day: dayLabel,
                module: example.0, title: example.1, summary: example.2, status: example.3,
                caveat: "Donnée fictive de démonstration, sans lien avec votre activité réelle.")
        }
        return GoalongAnalyticsPayload(current: .init(days: Array(days.suffix(count))),
            previous: .init(days: Array(days.prefix(count))), cards: cards, archiveNotice: nil,
            updatedAt: now, isPreview: true)
    }

    private static func makeDay(_ day: Date, calendar: Calendar) -> GoalongLocalAnalytics.Day {
        let seed = abs(calendar.ordinality(of: .day, in: .era, for: day) ?? 0)
        let scale = calendar.isDateInWeekend(day) ? 0.6 : 1.0
        var events: [HistoryEvent] = []
        func sample(at time: Date, app: String?, host: String? = nil, work: Bool? = true,
                    kind: EventKind = .heartbeat, suppression: SuppressionReason? = nil,
                    metadata: [String: String]? = nil) {
            events.append(HistoryEvent(id: "preview-\(Int(day.timeIntervalSince1970))-\(events.count)",
                sessionID: "developer-preview", timestamp: time, kind: kind,
                app: app.map { AppSnapshot(name: $0, bundleIdentifier: "preview." + $0, processIdentifier: 0) },
                url: host.map { URLSnapshot(value: "https://" + $0, host: $0, redactionApplied: true) },
                classification: .init(category: "Exemple", isWork: work, confidence: 0.9,
                    classifierVersion: "developer-preview-v1"),
                suppressionReason: suppression, metadata: metadata))
        }
        func block(hour: Int, minute: Int, duration: Int, app: String, host: String? = nil,
                   work: Bool? = true, idle: Bool = false, concealed: Bool = false) {
            guard let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { return }
            let length = max(1, Int(Double(duration) * scale))
            for offset in 0..<length {
                sample(at: start.addingTimeInterval(Double(offset * 60)), app: concealed ? nil : app,
                    host: host, work: work, suppression: concealed ? .manualPause : nil,
                    metadata: idle ? ["idle_seconds": "120"] : nil)
            }
            // Explicit end sample closes the last measured minute without extrapolation.
            sample(at: start.addingTimeInterval(Double(length * 60)), app: nil, kind: .recorderStopped)
        }
        block(hour: 9, minute: 0, duration: 52 + seed % 15, app: "Xcode")
        block(hour: 10, minute: 15, duration: 22 + seed % 9, app: "Safari", host: "docs.example.org")
        block(hour: 10, minute: 55, duration: 48 + seed % 14, app: "Figma")
        block(hour: 12, minute: 5, duration: 18, app: "Notes", work: nil)
        block(hour: 12, minute: 25, duration: 12, app: "Notes", idle: true)
        block(hour: 14, minute: 0, duration: 63 + seed % 17, app: "Xcode")
        block(hour: 15, minute: 25, duration: 25 + seed % 8, app: "Terminal")
        block(hour: 16, minute: 5, duration: 30 + seed % 6, app: "Safari", host: "design.example.org")
        block(hour: 16, minute: 45, duration: 16, app: "Mail")
        block(hour: 17, minute: 5, duration: 16, app: "Musique", work: false)
        // A few contiguous context changes, unlike gaps between the long work blocks.
        if let start = calendar.date(bySettingHour: 17, minute: 30, second: 0, of: day) {
            for minute in 0...12 {
                sample(at: start.addingTimeInterval(Double(minute * 60)),
                    app: minute % 4 < 2 ? "Notes" : "Calendrier", work: nil)
            }
            sample(at: start.addingTimeInterval(13 * 60), app: nil, kind: .recorderStopped)
        }
        block(hour: 18, minute: 0, duration: 10, app: "", concealed: true)
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        return GoalongLocalAnalytics.build(events: events, day: day, now: end, calendar: calendar)
    }
}
#endif
