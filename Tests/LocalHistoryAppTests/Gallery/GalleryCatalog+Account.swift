#if os(macOS)
import Foundation
import LocalHistoryCore
import SwiftUI
@testable import LocalHistoryApp

/// Réglages › Avancé › Mises à jour (the update row in its states) and Réglages › Site (the account card with a link,
/// and with an access the site refused). The update manager is a singleton: each entry sets a state and puts it back.
extension GalleryCatalog {
    private static let websiteOrigin = "https://goalong.example.org"

    /// The access file « Relier mon Mac » writes (0600), in the entry's home, removed afterwards.
    private static func installAccessFile(_ ctx: GalleryContext) throws -> URL {
        let file = ctx.home.appendingPathComponent(".goalong-gallery-access", isDirectory: false)
        try? FileManager.default.removeItem(at: file)
        try Data("galerie-jeton-d-acces".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        ctx.cleanups.append { try? FileManager.default.removeItem(at: file) }
        return file
    }

    private static func updateEntry(_ name: String, note: String, isConfigured: Bool = true, isChecking: Bool = false,
                                    availableVersion: String? = nil, result: SupportState = .unknown,
                                    message: String, checkedAt: Date? = nil, automatic: Bool = true) -> GalleryEntry {
        dashboard("mises-a-jour/\(name)", section: .settings, pane: .advanced, sizes: [.full(1240)], note: note,
                  configure: { _, ctx in
            let restore = SoftwareUpdateManager.shared.galleryShow(
                isConfigured: isConfigured, isChecking: isChecking, availableVersion: availableVersion, result: result,
                message: message, checkedAt: checkedAt, automatic: automatic)
            ctx.cleanups.append(restore)
        })
    }

    static var accountEntries: [GalleryEntry] {
        [
            updateEntry("disponible", note: "une version est prête à être installée", availableVersion: "9.9.0",
                        message: "Goalong History 9.9.0 est prête.", checkedAt: GalleryClock.at(9, 12)),
            updateEntry("a-jour", note: "la dernière vérification a trouvé la version actuelle", result: .upToDate,
                        message: "Goalong History est à jour.", checkedAt: GalleryClock.at(9, 12)),
            updateEntry("recherche", note: "une vérification est en cours", isChecking: true,
                        message: "Vérification en cours…", checkedAt: GalleryClock.at(9, 12)),
            updateEntry("erreur", note: "la dernière vérification a échoué (réseau)", result: .failed,
                        message: "La vérification n’a pas abouti : le serveur n’a pas répondu à temps. "
                            + "Votre version actuelle continue de fonctionner.", checkedAt: GalleryClock.at(9, 12)),
            updateEntry("non-configure", note: "copie sans mises à jour intégrées", isConfigured: false,
                        message: "Cette copie n’a pas de mises à jour intégrées : installez la version publiée pour les recevoir.", // UI-9 (54): the app's real text.
                        automatic: false),
            dashboard("compte/relie", section: .settings, pane: .website, note: "Mac relié au compte du site",
                      configure: { _, ctx in
                let file = try installAccessFile(ctx)
                ctx.defaults.set(websiteOrigin, forKey: "goalong.website.origin")
                ctx.defaults.set(file.path, forKey: "goalong.website.tokenFilePath")
            }),
            dashboard("compte/acces-refuse", section: .settings, pane: .website,
                      note: "le site a refusé l’accès enregistré", configure: { _, ctx in
                let file = try installAccessFile(ctx)
                ctx.defaults.set(websiteOrigin, forKey: "goalong.website.origin")
                ctx.defaults.set(file.path, forKey: "goalong.website.tokenFilePath")
                // The refusal mark the app writes when the site answers 401/403: the access file's fingerprint.
                ctx.defaults.set(SHA256Digest.hashHex(Data("galerie-jeton-d-acces".utf8)),
                                 forKey: GoalongWebsiteAutoSender.refusedCredentialKey)
            }),
        ]
    }
}
#endif
