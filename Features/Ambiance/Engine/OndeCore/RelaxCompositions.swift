import Foundation

/// Five separately authored relaxation worlds. Evidence-informed design, not a
/// universal prescription. The same pieces are available during meditation.
public enum RelaxCompositions {
    public static let ids = ["lagoon", "stillwater", "hearth", "reverie", "driftwood"]
    public static let profiles: [SoundProfile] = [
        make(8, "lagoon", "Lagoon", "WARM AMBIENT", "A deep, continuous harmonic tide. Quiet blooms and slowly changing common tones, without a beat.", 50),
        make(9, "stillwater", "Stillwater", "SOFT ACOUSTIC PIANO", "Spacious recorded piano, gentle low strings and long answering phrases. Room between the notes.", 56),
        make(10, "hearth", "Hearth", "CHAMBER ENSEMBLE", "Warm cellos, violas, restrained horns and woodwinds. Sustained, overlapping voices without percussion.", 52),
        make(11, "reverie", "Reverie", "WORDLESS CHOIR", "Soft synthesized vowels, low strings and distant harp. Common tones connect without words or vocal solos.", 48),
        make(12, "driftwood", "Driftwood", "WOOD & HARP", "Rounded wooden resonances answer a recorded harp over a quiet harmonic bed. Unhurried, composed motion.", 62)
    ]
    private static func make(_ score: Double, _ id: String, _ title: String, _ subtitle: String, _ description: String, _ tempo: Double) -> SoundProfile {
        var c = GenerativeSettings()
        c.profileID = id; c.composition = score; c.seed = UInt64(11100 + Int(score)); c.tempo = tempo
        c.density = 0.28; c.brightness = 0.20; c.warmth = 0.85; c.space = 0.72
        c.movement = 0.10; c.evolution = 0.40; c.stability = 1; c.character = 0.85
        c.texture = 0; c.pulse = 0; c.drive = 0; c.punch = 0; c.settleMinutes = 0
        c.bass = 0.48; c.orchestra = 0
        c.strings = 0; c.brass = 0; c.woods = 0; c.harp = 0; c.ostinato = 0; c.percussion = 0
        switch Int(score) {
        case 8:
            c.bass = 0.67; c.space = 0.82; c.density = 0.14; c.brightness = 0.13
        case 9:
            c.orchestra = 1; c.piano = 0.90; c.strings = 0.32
            c.space = 0.55; c.density = 0.29; c.bass = 0.22; c.brightness = 0.26
        case 10:
            c.orchestra = 1; c.strings = 0.82; c.brass = 0.37; c.woods = 0.60
            c.space = 0.70; c.density = 0.24; c.bass = 0.40; c.brightness = 0.24
        case 11:
            c.orchestra = 0.60; c.strings = 0.38; c.harp = 0.33; c.vocals = 0.63
            c.space = 0.82; c.density = 0.22; c.bass = 0.51; c.brightness = 0.18
        default:
            c.orchestra = 0.70; c.strings = 0.29; c.harp = 0.72
            c.space = 0.66; c.density = 0.31; c.bass = 0.42; c.brightness = 0.22
        }
        return SoundProfile(id: id, title: title, mode: .relax, subtitle: subtitle, description: description, configuration: c)
    }
}
