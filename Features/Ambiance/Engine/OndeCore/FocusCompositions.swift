import Foundation

/// Eight small, authored vocabularies. The long-form planners develop them without
/// changing genre or promising a clinically established optimum.
public enum FocusCompositions {
    public static let ids = ["ambre", "canopee", "meridien", "sillage", "filigrane", "confluence", "sanctuaire", "gravite"]
    public static let profiles: [SoundProfile] = [
        make(5, "ambre", "Amber", "ELECTRIC KEYS · 82 BPM", "Velvety chords, supple bass and piano responses. Long phrases without added lo-fi hiss.", 82),
        make(6, "canopee", "Canopy", "MELODIC PERCUSSION · 94 BPM", "Wooden resonances, acoustic harp and low strings. Two answering motifs, without random improvisation.", 94),
        make(7, "meridien", "Meridian", "MINIMAL HOUSE · 108 BPM", "Driving bass, broad chords and steady offbeats. An evolving arrangement without drops.", 108),
        make(1, "sillage", "Slipstream", "DEEP ELECTRONIC · 92 BPM", "Articulated bass and a dark theme. Questions, answers and inversions without breaking the rhythm.", 92),
        make(2, "filigrane", "Filigree", "ACOUSTIC PIANO · 78 BPM", "Soft piano unfolds in eight-bar phrases. The left hand anchors the rhythm as the answers develop.", 78),
        make(3, "confluence", "Confluence", "HYBRID ORCHESTRA · 88 BPM", "Rhythmic cellos, sustained strings and sections that gradually shift their place in the ensemble.", 88),
        make(4, "sanctuaire", "Sanctuary", "SYNTHESIZED VOCALS · 86 BPM", "Sustained vowels, answering harp and a steady bass. Harmony that breathes without words.", 86),
        make(13, "gravite", "Gravity", "DEEP BASS · 120 BPM", "A soft kick and a sustained sub share one deep pulse. Offbeat bass, slow chords and a few quiet notes, with nothing sudden.", 120)
    ]
    private static func make(_ score: Double, _ id: String, _ title: String, _ subtitle: String, _ description: String, _ tempo: Double) -> SoundProfile {
        var c = GenerativeSettings()
        c.profileID = id; c.composition = score; c.seed = UInt64(8100 + Int(score)); c.tempo = tempo
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
        case 13:
            // Texture is the depth of the fast tremolo on the chords; zero removes it.
            c.bass = 0.90; c.pulse = 0.45; c.drive = 0.62; c.punch = 0.55
            c.space = 0.42; c.density = 0.40; c.orchestra = 0; c.texture = 0.55
            c.warmth = 0.62; c.brightness = 0.42
        default:
            c.bass = 0.85; c.pulse = 0.30; c.drive = 0.72; c.punch = 0.62
            c.space = 0.55; c.density = 0.35; c.orchestra = 0; c.warmth = 0.63; c.brightness = 0.35
        }
        return SoundProfile(id: id, title: title, mode: .focus, subtitle: subtitle, description: description, configuration: c)
    }
    public static func rationale(_ id: String) -> String {
        switch id {
        case "ambre": return "Synthesized electric keys with recorded piano responses. Eight bars to introduce, develop and resolve an idea, without intrusive solos."
        case "canopee": return "Synthesized wooden resonators and recorded harp. Interwoven parts develop by phrase, not by randomly dropping beats."
        case "meridien": return "A steady house foundation, composed offbeats and a long-form progression. No breaks or drops designed to pull attention back to the music."
        case "sillage": return "Bass keeps its anchor while the theme develops an eight-bar response. Musical choices evolve within the same soundscape."
        case "filigrane": return "The acoustic piano keeps its soft touch while developing responses and inversions instead of looping a single cell."
        case "confluence": return "Instrument sections stay coordinated. Their balance changes slowly over minutes, rather than each part changing direction on every beat."
        case "sanctuaire": return "A synthesized choir, not recorded singers. Common notes connect the chords as the harp develops its answers. Vocals can be turned off."
        case "gravite": return "One beat-locked oscillator is both the soft kick and the sub, so the low end repeats exactly. The chords carry a fast tremolo that can be set to zero."
        default: return ""
        }
    }
}
