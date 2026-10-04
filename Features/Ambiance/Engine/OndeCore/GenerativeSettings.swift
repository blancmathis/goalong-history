import Foundation

/// Rendering controls for Goalong; persisted settings live in AmbianceSettings.
public struct GenerativeSettings {
    public var seed: UInt64 = 42
    public var density: Double = 0.30
    public var brightness: Double = 0.16
    public var movement: Double = 0.12
    public var space: Double = 0.54
    public var texture: Double = 0.04
    public var pulse: Double = 0.64
    public var evolution: Double = 0.12
    public var settleMinutes: Double = 0
    public var bass: Double = 0.78
    public var tempo: Double = 72
    public var stability: Double = 0.98
    public var warmth: Double = 0.86
    public var character: Double = 0.20
    public var drive: Double = 0
    public var punch: Double = 0
    public var orchestra: Double = 0
    public var strings: Double = 0.5
    public var brass: Double = 0.5
    public var woods: Double = 0.5
    public var harp: Double = 0.5
    public var ostinato: Double = 0.5
    public var percussion: Double = 0.5
    public var composition: Double = 0
    public var vocals: Double = 0
    public var piano: Double = 0
    public var profileID: String? = nil
    public init() {}
    public static let keys = ["density", "brightness", "movement", "space", "texture", "pulse", "evolution", "settleMinutes", "bass", "tempo", "stability", "warmth", "character", "drive", "punch", "orchestra", "strings", "brass", "woods", "harp", "ostinato", "percussion", "composition", "vocals", "piano"]
    /// The first eight ABI slots predate gain (slot 8). New controls start at slot 9.
    public var values: [Double] { [density, brightness, movement, space, texture, pulse, evolution, settleMinutes, bass, tempo, stability, warmth, character, drive, punch, orchestra, strings, brass, woods, harp, ostinato, percussion, composition, vocals, piano] }
    public static func dspIndex(_ index: Int) -> Int32 { Int32(index < 8 ? index : index + 1) }
    public static func range(_ key: String) -> ClosedRange<Double> { key == "composition" ? 0...15 : key == "tempo" ? 40...120 : key == "settleMinutes" ? 0...120 : 0...1 }
    public mutating func set(_ key: String, _ value: Double) throws {
        guard Self.keys.contains(key) else { throw OndeError("invalid_key", "Generator keys: \(Self.keys.joined(separator: ", ")).") }
        let range = Self.range(key)
        guard value.isFinite, range.contains(value), (key != "composition" || value.rounded(.down) == value) else { throw OndeError("invalid_argument", "\(key) must be a number in \(range.lowerBound)...\(range.upperBound).") }
        switch key {
        case "density": density = value
        case "brightness": brightness = value
        case "movement": movement = value
        case "space": space = value
        case "texture": texture = value
        case "pulse": pulse = value
        case "evolution": evolution = value
        case "settleMinutes": settleMinutes = value
        case "bass": bass = value
        case "tempo": tempo = value
        case "stability": stability = value
        case "warmth": warmth = value
        case "character": character = value
        case "drive": drive = value
        case "punch": punch = value
        case "orchestra": orchestra = value
        case "strings": strings = value
        case "brass": brass = value
        case "woods": woods = value
        case "harp": harp = value
        case "ostinato": ostinato = value
        case "percussion": percussion = value
        case "composition": composition = value
        case "vocals": vocals = value
        default: piano = value
        }
    }
    public func validated() throws -> Self {
        var copy = self
        for (k, v) in zip(Self.keys, values) { try copy.set(k, v) }
        guard seed <= 9_007_199_254_740_991 else { throw OndeError("invalid_seed", "Seed must be an exact JSON integer <= 2^53-1.") }
        return copy
    }
}
public struct SoundProfile {
    public let id: String
    public let title: String
    public let mode: SessionMode
    public let subtitle: String
    public let description: String
    public let configuration: GenerativeSettings

}
extension SessionMode {
    public var dspMode: Int32 { switch self { case .focus: return 0; case .relax: return 1; case .meditation: return 2 } }
}
