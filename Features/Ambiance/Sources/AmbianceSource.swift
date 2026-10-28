import Foundation
import os
import OndeCore

public struct AmbianceSource: Identifiable, Equatable {
    public enum Kind: Equatable, CaseIterable {
        case focus, relax, texture, ownFile
        /// The one French name of each kind, used by the Ambiance page and the menu-bar panel.
        public var displayName: String {
            switch self { case .focus: return "Concentration"; case .relax: return "Détente"; case .texture: return "Texture"; case .ownFile: return "Ma musique" }
        }
    }
    public let id: String
    public let title: String
    public let kind: Kind
    public let isAvailable: Bool
    public let path: String?
    public var requiredPack: String? {
        switch kind { case .focus, .relax: return "orchestra"; case .texture: return "textures"; case .ownFile: return nil }
    }
    public init(id: String, title: String, kind: Kind, isAvailable: Bool, path: String? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.isAvailable = isAvailable; self.path = path
    }
    static let compositionTitles = [
        "ambre": "Ambre", "canopee": "Canopée", "meridien": "Méridien", "sillage": "Sillage",
        "filigrane": "Filigrane", "confluence": "Confluence", "sanctuaire": "Sanctuaire", "gravite": "Gravité", "orbit": "Orbite", "sonar": "Sonar",
        "lagoon": "Lagon", "stillwater": "Eau calme", "hearth": "Foyer", "reverie": "Rêverie", "driftwood": "Bois flotté",
    ]
    static let textures = [("rain", "Pluie douce"), ("ocean", "Marée"), ("brown", "Velours brun"), ("pink", "Air rose"), ("aube", "Aube")]
    var profile: SoundProfile? {
        guard kind == .focus || kind == .relax else { return nil }
        return (FocusCompositions.profiles + RelaxCompositions.profiles).first { $0.id == id }
    }
}

public struct AmbianceDiagnostics: Equatable {
    public var mappedBytes: Int = 0
    /// Current process RSS, not a claimed audio-only allocation.
    public var residentBytes: UInt64 = 0
    public var copiedSampleBytes: Int = 0
    public var engineRunning = false
    public var runtimeCreated = false
    public init() {}
}

public enum AmbianceError: Error, LocalizedError {
    case invalidPack(String), cancelled, unavailable, noAudioOutput, disabled, audioBoundary, networkBoundary, network, tooSlow, serverUnavailable
    /// `needed`: the size of the pack being downloaded; nil when unknown (no figure is claimed then).
    case diskFull(needed: Int64?)
    public var errorDescription: String? {
        switch self {
        case .invalidPack(let detail):
            // Size or SHA-256 mismatch: the file is damaged; a fresh copy usually fixes it.
            guard ["SHA-256 incorrect", "taille incorrecte"].contains(detail) else { return "Pack invalide : \(detail)" }
            return "Pack invalide : \(detail). Le fichier est peut-être abîmé. Téléchargez le pack à nouveau."
        case .cancelled: return "Téléchargement annulé."
        case .network: return "Connexion impossible. Vérifiez Internet puis réessayez."
        case .diskFull(let needed):
            guard let needed, needed > 0 else { return "Espace disque insuffisant. Libérez de la place puis réessayez." }
            return "Espace disque insuffisant. Libérez de la place (environ \((needed + 999_999) / 1_000_000) Mo) puis réessayez."
        case .tooSlow: return "Téléchargement trop lent. Réessayez avec une connexion plus rapide."
        case .serverUnavailable: return "Le pack est indisponible pour le moment. Réessayez plus tard."
        case .unavailable: return "Cette source est indisponible. Installez son pack ou retrouvez le fichier."
        case .noAudioOutput: return "Aucune sortie audio disponible. Branchez un casque ou des haut-parleurs, ou choisissez une sortie dans Réglages Système > Son, puis relancez."
        case .disabled: return "Le module Ambiance est désactivé."
        case .audioBoundary: return "La lecture audio attend la revue de la frontière de sécurité de Goalong."
        case .networkBoundary: return "Le téléchargement HTTPS attend la revue de la frontière réseau de Goalong. Un pack local vérifié peut être installé."
        }
    }
}

extension AmbianceError {
    private static let log = Logger(subsystem: "app.goalong", category: "Ambiance")
    /// The member sees a short French sentence; the raw system error stays in the log.
    static func userMessage(_ prefix: String, _ error: Error) -> String {
        log.error("\(prefix, privacy: .public): \(String(describing: error), privacy: .private)")
        if let known = error as? AmbianceError, let text = known.errorDescription { return "\(prefix) : \(text)" }
        return "\(prefix). Réessayez, ou choisissez une autre source."
    }
}
