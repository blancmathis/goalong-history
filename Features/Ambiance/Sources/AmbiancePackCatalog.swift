import Foundation

public enum AmbiancePackCatalog {
    public static let packs: [AmbiancePack] = [
        AmbiancePack(id: "orchestra", title: "Orchestre acoustique", bytes: 77158400, url: URL(string: "https://github.com/blancmathis/goalong-history/releases/download/ambiance-packs-v1/orchestra.tar")!, sha256: "d8535aa60dbbb9b8b44897a3de0ef26c532b9e3f2a368a5fbe9c4f62462c2489"),
        AmbiancePack(id: "textures", title: "Textures et Aube", bytes: 83363840, url: URL(string: "https://github.com/blancmathis/goalong-history/releases/download/ambiance-packs-v1/textures.tar")!, sha256: "eee48c8c039e50d1e23f824c3de4151252c5e66e8c42d1264c3daa3b2f5da3a2"),
    ]
}
