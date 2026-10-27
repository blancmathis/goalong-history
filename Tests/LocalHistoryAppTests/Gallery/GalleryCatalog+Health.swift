#if os(macOS)
import Foundation
import SwiftUI
@testable import LocalHistoryApp
import LocalHistoryCore
import LocalHistoryQueryCLI

/// The Apple Santé import sheet (Réglages › Sources): before a file, while it is read, a kept preview, and a refused file.
extension GalleryCatalog {
    static var healthImportEntries: [GalleryEntry] {
        [
            panel("sante/import-vide", width: 800, height: 720, clock: .injected, note: "feuille Apple Santé, aucun fichier choisi") { _ in
                AnyView(GoalongHealthImportSheet())
            },
            panel("sante/import-lecture", width: 800, height: 720, clock: .injected, note: "lecture locale de export.xml en cours") { _ in
                AnyView(GoalongHealthImportSheet(gallery: .reading))
            },
            panel("sante/import-reussi", width: 800, height: 720, clock: .injected,
                  note: "aperçu d’une journée lue puis conservée sur ce Mac") { _ in
                let result = try galleryHealthImport()
                let message = "\(FrenchCount.count(result.dayCount, "journée", "journées")) Santé \(FrenchCount.word(result.dayCount, "conservée", "conservées")) sur ce Mac. Aucun envoi effectué."
                return AnyView(GoalongHealthImportSheet(gallery: .imported(result, message: message)))
            },
            panel("sante/import-erreur", width: 800, height: 720, clock: .injected, note: "le fichier choisi n’est pas un export Apple Santé") { _ in
                // The product's own message for a file the import refuses.
                let options = GoalongHealthImportOptions(from: GalleryClock.today, through: GalleryClock.at(23, 59), timezone: GalleryClock.timeZone)
                var text = "Ce fichier n’a pas pu être lu."
                do { _ = try GoalongHealthImport.read(data: Data("<html></html>".utf8), options: options) } catch { text = goalongUserMessage(error) }
                return AnyView(GoalongHealthImportSheet(gallery: .failed(text)))
            },
        ]
    }
}
#endif
