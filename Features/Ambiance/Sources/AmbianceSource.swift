import Foundation
import OndeCore

public struct AmbianceSource: Identifiable, Equatable {
    public enum Kind: Equatable { case focus, relax, texture, ownFile }
    public let id: String
    public let title: String
    public let kind: Kind
    public let isAvailable: Bool
    public let path: String?
    public var requiredPack: String? {
        switch kind { case .focus, .relax: return "orchestra"; case .texture: return "textures"; case .ownFile: return nil }
    }
    init(id: String, title: String, kind: Kind, isAvailable: Bool, path: String? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.isAvailable = isAvailable; self.path = path
    }
    static let compositionTitles = [
        "ambre": "Ambre", "canopee": "Canopée", "meridien": "Méridien", "sillage": "Sillage",
        "filigrane": "Filigrane", "confluence": "Confluence", "sanctuaire": "Sanctuaire", "gravite": "Gravité",
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
    case invalidPack(String), cancelled, unavailable, disabled, audioBoundary, networkBoundary
    public var errorDescription: String? {
        switch self {
        case .invalidPack(let detail): return "Pack invalide : \(detail)"
        case .cancelled: return "Téléchargement annulé."
        case .unavailable: return "Cette source est indisponible. Installez son pack ou retrouvez le fichier."
        case .disabled: return "Le module Ambiance est désactivé."
        case .audioBoundary: return "La lecture audio attend la revue de la frontière de sécurité de Goalong."
        case .networkBoundary: return "Le téléchargement HTTPS attend la revue de la frontière réseau de Goalong. Un pack local vérifié peut être installé."
        }
    }
}
