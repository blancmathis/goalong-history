#if os(macOS)
import Ambiance
import SwiftUI

/// What a piece sounds like, as the shape of its line: steady for focus, slow swells to rest,
/// fine grain for rain. Same piece, same line, on every Mac.
enum AmbianceWaveCharacter: Equatable {
    case focus, relax, rain, ocean, brown, pink, dawn, own

    init(_ source: AmbianceSource) {
        switch source.kind {
        case .focus: self = .focus
        case .relax: self = .relax
        case .ownFile: self = .own
        case .texture:
            switch source.id {
            case "rain": self = .rain
            case "ocean": self = .ocean
            case "brown": self = .brown
            case "pink": self = .pink
            default: self = .dawn
            }
        }
    }

    /// Frequency ranges (cycles across the line) and their weight.
    fileprivate var bands: [(ClosedRange<Double>, Double)] {
        switch self {
        case .focus: return [(3...4.5, 0.55), (7...10, 0.3), (14...18, 0.15)]
        case .relax: return [(1.2...2, 0.75), (3...4.5, 0.25)]
        case .rain: return [(2...3, 0.3)] + Array(repeating: (22...40, 0.07), count: 10)
        case .ocean: return [(1...1.6, 0.8), (2.5...3.5, 0.2)]
        case .brown: return [(0.8...1.4, 0.5), (1.8...2.6, 0.3), (3...4, 0.2)]
        case .pink: return [(4...6, 0.35), (9...12, 0.28), (16...22, 0.2), (28...34, 0.17)]
        case .dawn: return [(2...3, 0.65), (5...7, 0.35)]
        case .own: return [(2...2.5, 0.6), (5...6, 0.4)]
        }
    }
}

struct AmbianceWaveShape: Shape {
    let seed: String
    let character: AmbianceWaveCharacter

    func path(in rect: CGRect) -> Path {
        var random = SplitMix(seed: Self.hash(seed))
        let bands = character.bands
        var parts: [(frequency: Double, weight: Double, phase: Double)] = []
        parts.reserveCapacity(bands.count)
        var total = 0.0
        for (band, weight) in bands {
            let frequency = band.lowerBound + random.next() * (band.upperBound - band.lowerBound)
            let phase = random.next() * 2 * .pi
            parts.append((frequency, weight, phase))
            total += weight
        }
        let count = max(48, Int(rect.width / 2))
        let amplitude = rect.height / 2 * 0.92
        var points: [CGPoint] = []
        points.reserveCapacity(count + 1)
        for index in 0...count {
            let x = Double(index) / Double(count)
            // The line starts and ends on its axis, like a thread pulled at both ends.
            var envelope = pow(sin(Double.pi * x), 0.7)
            if character == .dawn { envelope *= 0.2 + 0.8 * x }
            var value = 0.0
            for part in parts {
                value += part.weight * sin(2 * .pi * part.frequency * x + part.phase)
            }
            value /= total
            points.append(CGPoint(x: rect.minX + rect.width * x, y: rect.midY - amplitude * envelope * value))
        }
        var path = Path()
        path.addLines(points)
        return path
    }

    private static func hash(_ text: String) -> UInt64 {
        var result: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { result = (result ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return result
    }

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(UInt64(1) << 53)
        }
    }
}

/// A piece's line. Lime while it plays; dotted while its sounds are not on this Mac yet,
/// filling from the left as they download.
struct AmbianceWave: View {
    enum Look: Equatable { case idle, active, waiting, progress(Double) }

    let seed: String
    let character: AmbianceWaveCharacter
    var look: Look = .idle
    var lineWidth: CGFloat = 1.5

    var body: some View {
        let shape = AmbianceWaveShape(seed: seed, character: character)
        let solid = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        let dotted = StrokeStyle(lineWidth: max(1, lineWidth - 0.5), lineCap: .round, dash: [2, 4])
        ZStack {
            switch look {
            case .idle:
                shape.stroke(LHTheme.secondaryText, style: solid)
            case .active:
                shape.stroke(LHTheme.accent, style: solid)
            case .waiting:
                shape.stroke(LHTheme.tertiaryText, style: dotted)
            case .progress(let fraction):
                let done = min(1, max(0, fraction))
                shape.trim(from: done, to: 1).stroke(LHTheme.tertiaryText, style: dotted)
                shape.trim(from: 0, to: done).stroke(LHTheme.accent, style: solid)
            }
        }
        .accessibilityHidden(true)
    }
}
#endif
