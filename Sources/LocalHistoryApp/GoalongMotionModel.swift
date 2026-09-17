import Foundation

/// Native port of the approved Passage Blender/SVG rig. No I/O or timers.
/// All times are monotonic seconds; the cycle phase is never a percentage.
enum GoalongMotion {
    static let cycle = 2.4
    static let transition = 0.3
    static let frequency = 2 * Double.pi / cycle

    struct Sample: Equatable {
        var p: [Double] = [0, 0]
        var v: [Double] = [0, 0]
        var a: [Double] = [0, 0]
        static let rest = Sample()
    }
    struct Point: Equatable { let x: Double; let y: Double }
    // Anchor, incoming handle, outgoing handle. Same handles as the delivered rig.
    static let loop: [[[Double]]] = [
        [[2.08, 9], [2.08, 16.2], [2.08, 1.8]],
        [[13.26, 9], [9.62, 1.44], [16.64, 16.56]],
        [[23.92, 9], [23.92, 16.2], [23.92, 1.8]],
        [[13.26, 9], [16.64, 1.44], [9.62, 16.56]],
    ]
    static let arm: [[[Double]]] = [
        [[2.08, 9], [2.08, 9], [4.7666666667, 9]],
        [[10.14, 9], [7.4533333333, 9], [11.44, 9]],
        [[12.74, 10.62], [12.74, 9.72], [12.74, 10.62]],
    ]

    static func activity(_ t: Double) -> Sample {
        let w = frequency, angle = w * t
        return Sample(
            p: [0.78 * sin(angle) + 0.08 * (1 - cos(2 * angle)), 0.35 * (1 - cos(angle))],
            v: [0.78 * w * cos(angle) + 0.16 * w * sin(2 * angle), 0.35 * w * sin(angle)],
            a: [-0.78 * w * w * sin(angle) + 0.32 * w * w * cos(2 * angle), 0.35 * w * w * cos(angle)]
        )
    }
    private static func polynomial(_ coefficients: [Double], _ u: Double, _ order: Int) -> Double {
        var values = coefficients
        for _ in 0..<order {
            values = Array(values.dropFirst().enumerated().map { Double($0.offset + 1) * $0.element })
        }
        return values.reversed().reduce(0) { $0 * u + $1 }
    }
    static func entry(_ t: Double, initial: Sample = .rest) -> Sample {
        if t >= transition { return activity(t - transition) }
        let d = transition, u = min(1, max(0, t / d)), target = activity(0)
        let carry = release(initial, at: t)
        var values = [[Double]]()
        for order in 0..<3 {
            values.append((0..<2).map { i in
                (d * target.v[i] * polynomial([0, 0, 0, -4, 7, -3], u, order)
                + d * d * target.a[i] * polynomial([0, 0, 0, 0.5, -1, 0.5], u, order)) / pow(d, Double(order))
            })
        }
        return Sample(p: zip(values[0], carry.p).map(+), v: zip(values[1], carry.v).map(+), a: zip(values[2], carry.a).map(+))
    }
    static func release(_ sample: Sample, at t: Double) -> Sample {
        if t >= transition { return .rest }
        let d = transition, u = min(1, max(0, t / d))
        var values = [[Double]]()
        for order in 0..<3 {
            let position = polynomial([1, 0, 0, -10, 15, -6], u, order)
            let velocity = polynomial([0, 1, 0, -6, 8, -3], u, order)
            let acceleration = polynomial([0, 0, 0.5, -1.5, 1.5, -0.5], u, order)
            let denominator = pow(d, Double(order))
            var row = [Double]()
            for i in 0..<2 {
                let p = sample.p[i] * position
                let v = d * sample.v[i] * velocity
                let a = d * d * sample.a[i] * acceleration
                row.append((p + v + a) / denominator)
            }
            values.append(row)
        }
        return Sample(p: values[0], v: values[1], a: values[2])
    }
    static func geometry(_ source: [[[Double]]], q: Double = 0, b: Double = 0) -> [[Point]] {
        source.map { handles in handles.map { point in
            let x = point[0] - 13, y = 9 - point[1]
            let weight = abs(x) <= 10.92 ? pow(cos(Double.pi * x / 21.84), 2) : 0
            return Point(x: x + 2.4 * weight * q + 13, y: 9 - (y + 0.7 * weight * b))
        } }
    }
    struct State {
        enum Phase { case idle, busy, release }
        private(set) var phase = Phase.idle
        private(set) var since = 0.0
        private var initial = Sample.rest
        var busy: Bool { phase == .busy }
        func sample(at time: Double) -> Sample {
            switch phase {
            case .idle: return .rest
            case .busy: return GoalongMotion.entry(max(0, time - since), initial: initial)
            case .release: return GoalongMotion.release(initial, at: max(0, time - since))
            }
        }
        mutating func setBusy(_ active: Bool, at time: Double) {
            guard active != busy else { return }
            initial = sample(at: time)
            since = time
            phase = active ? .busy : .release
        }
        mutating func settle() { phase = .idle; initial = .rest }
    }
}
