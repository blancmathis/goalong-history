#if os(macOS)
import Foundation
import SwiftUI
@testable import LocalHistoryApp
import LocalHistoryQueryCLI

/// One image per named view of Activité (`GoalongActivityDetail`), on the day of `activite/jour-realiste`.
/// « Appels et agenda » has its own states in `agenda/`. `code` and `sleep` need data the base fixture lacks, so they
/// have their own entries below: agent conversations with project folders, and an Apple Health import of the day.
extension GalleryCatalog {
    static var activityDetailEntries: [GalleryEntry] {
        GoalongActivityDetail.allCases.filter { ![.agenda, .code, .sleep].contains($0) }.map { shown in
            dashboard("activite/detail-\(shown == .screenTime ? "temps-ecran" : shown.rawValue)", section: .overview, sizes: [.full(1240)], fixture: .classified,
                      note: "vue nommée « \(shown.title(isDay: true)) » ouverte depuis « Explorer la journée »",
                      prepare: { ctx in
                GoalongAnalyticsPage.galleryDetail = shown
                ctx.cleanups.append { GoalongAnalyticsPage.galleryDetail = nil }
            })
        } + [codeEntry, sleepEntry]
    }

    private static var codeEntry: GalleryEntry {
        dashboard("activite/detail-code", section: .overview, sizes: [.full(1240)], fixture: .classified,
                  note: "vue « Agents et code » : quatre conversations d’agents sur deux projets, une sans projet",
                  prepare: { ctx in
            GoalongAnalyticsPage.galleryDetail = .code
            ctx.cleanups.append { GoalongAnalyticsPage.galleryDetail = nil }
        }, configure: { model, _ in installConversations(.projects, model) })
    }

    /// An Apple Health import of the gallery day, written through the product's own import and archive.
    private static func installHealthImport() throws {
        let zone = GalleryClock.timeZone
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = zone; format.dateFormat = "yyyy-MM-dd HH:mm:ss xx"
        func record(_ type: String, _ value: String, unit: String = "count", _ start: Date, _ end: Date) -> String {
            "<Record type=\"\(type)\" sourceName=\"Apple Watch\" unit=\"\(unit)\" value=\"\(value)\" startDate=\"\(format.string(from: start))\" endDate=\"\(format.string(from: end))\"/>"
        }
        func sleep(_ stage: String, _ from: (Int, Int, Int), _ to: (Int, Int, Int)) -> String {
            record("HKCategoryTypeIdentifierSleepAnalysis", "HKCategoryValueSleepAnalysis\(stage)", unit: "",
                   GalleryClock.at(from.1, from.2, dayOffset: from.0), GalleryClock.at(to.1, to.2, dayOffset: to.0))
        }
        // A night from 23:10 the day before to 06:50, split at midnight by the import; two walks and a run.
        let body = [
            sleep("AsleepCore", (-1, 23, 10), (0, 1, 0)), sleep("AsleepDeep", (0, 1, 0), (0, 2, 30)),
            sleep("AsleepCore", (0, 2, 30), (0, 4, 0)), sleep("AsleepREM", (0, 4, 0), (0, 5, 15)),
            sleep("Awake", (0, 5, 15), (0, 5, 25)), sleep("AsleepCore", (0, 5, 25), (0, 6, 50)),
            record("HKQuantityTypeIdentifierStepCount", "4200", GalleryClock.at(8, 0), GalleryClock.at(8, 40)),
            record("HKQuantityTypeIdentifierStepCount", "3900", GalleryClock.at(8, 40), GalleryClock.at(9, 15)),
            "<Workout sourceName=\"Apple Watch\" workoutActivityType=\"HKWorkoutActivityTypeRunning\" startDate=\"\(format.string(from: GalleryClock.at(7, 15)))\" endDate=\"\(format.string(from: GalleryClock.at(7, 55)))\" duration=\"40\" durationUnit=\"min\"/>",
        ].joined()
        let xml = Data("<?xml version=\"1.0\"?><HealthData locale=\"fr_FR\"><ExportDate value=\"\(format.string(from: GalleryClock.at(9, 20)))\"/>\(body)</HealthData>".utf8)
        let day = GalleryClock.today
        let options = GoalongHealthImportOptions(from: day, through: GalleryClock.at(23, 59), timezone: zone)
        try GoalongHealthArchive.save(GoalongHealthImport.read(data: xml, options: options), root: AppPaths.applicationSupportDirectory)
    }

    private static var sleepEntry: GalleryEntry {
        dashboard("activite/detail-sommeil", section: .overview, sizes: [.full(1240)], fixture: .classified,
                  note: "vue « Sommeil et activité » : import Apple Santé du jour, phases du sommeil, pas et une séance",
                  prepare: { ctx in
            try installHealthImport()
            // The import is the entry's own: no other image of the same day may find a Health file.
            ctx.cleanups.append { try? FileManager.default.removeItem(at: AppPaths.applicationSupportDirectory.appendingPathComponent("health")) }
            GoalongAnalyticsPage.galleryDetail = .sleep
            ctx.cleanups.append { GoalongAnalyticsPage.galleryDetail = nil }
        })
    }
}
#endif
