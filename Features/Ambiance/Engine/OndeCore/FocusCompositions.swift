import Foundation

/// Eight small, authored vocabularies. The long-form planners develop them without
/// changing genre or promising a clinically established optimum.
public enum FocusCompositions {
    public static let profiles: [SoundProfile] = [
        make(5, "ambre", 82),
        make(6, "canopee", 94),
        make(7, "meridien", 108),
        make(1, "sillage", 92),
        make(2, "filigrane", 78),
        make(3, "confluence", 88),
        make(4, "sanctuaire", 86),
        make(13, "gravite", 120),
        make(14, "orbit", 120),
        make(15, "sonar", 120)
    ]
    private static func make(_ score: Double, _ id: String, _ tempo: Double) -> SoundProfile {
        var c = GenerativeSettings()
        c.composition = score; c.seed = UInt64(8100 + Int(score)); c.tempo = tempo
        c.stability = 1; c.evolution = 0.38; c.texture = 0; c.movement = 0.14
        c.brightness = 0.30; c.warmth = 0.70; c.settleMinutes = 0
        c.strings = 0; c.brass = 0; c.woods = 0; c.harp = 0; c.ostinato = 0; c.percussion = 0
        switch Int(score) {
        case 1:
            c.bass = 0.88; c.pulse = 0.38; c.drive = 0.66; c.punch = 0.55
            c.space = 0.44; c.density = 0.40; c.character = 0.48; c.orchestra = 0
        case 2:
            c.bass = 0.15; c.pulse = 0; c.drive = 0; c.punch = 0
            c.space = 0.46; c.density = 0.36; c.orchestra = 1; c.piano = 0.87; c.strings = 0.28
        case 3:
            c.bass = 0.78; c.pulse = 0.25; c.drive = 0.39; c.punch = 0.34
            c.space = 0.62; c.density = 0.46; c.orchestra = 1
            c.strings = 0.82; c.brass = 0.40; c.woods = 0.24; c.harp = 0.26; c.ostinato = 0.63; c.percussion = 0.38
        case 4:
            c.bass = 0.78; c.pulse = 0.33; c.drive = 0.39; c.punch = 0.28
            c.space = 0.75; c.density = 0.29; c.orchestra = 0.80; c.vocals = 0.76
            c.strings = 0.42; c.harp = 0.32; c.percussion = 0.18
        case 5:
            c.bass = 0.62; c.pulse = 0.32; c.drive = 0.32; c.punch = 0.24
            c.space = 0.48; c.density = 0.40; c.orchestra = 0.18; c.piano = 0.48
            c.warmth = 0.75; c.brightness = 0.34
        case 6:
            c.bass = 0.59; c.pulse = 0.24; c.drive = 0.30; c.punch = 0.18
            c.space = 0.56; c.density = 0.36; c.orchestra = 0.35
            c.strings = 0.42; c.harp = 0.58; c.percussion = 0.32; c.brightness = 0.35
        case 13, 14, 15:
            // Texture is the depth of the fast tremolo on the chords; zero removes it.
            c.bass = 0.90; c.pulse = 0.45; c.drive = 0.62; c.punch = 0.55
            c.space = 0.42; c.density = 0.40; c.orchestra = 0; c.texture = 0.55
            c.warmth = 0.62; c.brightness = 0.42
        default:
            c.bass = 0.85; c.pulse = 0.30; c.drive = 0.72; c.punch = 0.62
            c.space = 0.55; c.density = 0.35; c.orchestra = 0; c.warmth = 0.63; c.brightness = 0.35
        }
        return SoundProfile(id: id, mode: .focus, configuration: c)
    }
}
