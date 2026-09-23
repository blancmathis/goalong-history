import Foundation

public enum JevScreenEffect: String, Codable, CaseIterable, Sendable {
    case dim, red, dimAndRed
    public var title: String {
        switch self {
        case .dim: return "Assombrir"
        case .red: return "Voile rouge"
        case .dimAndRed: return "Assombrir + rouge"
        }
    }
}

public struct JevInterventionStage: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var afterMinutes: Int
    public var effect: JevScreenEffect
    public var intensity: Int
    public init(enabled: Bool = true, afterMinutes: Int, effect: JevScreenEffect, intensity: Int) {
        self.enabled = enabled; self.afterMinutes = afterMinutes
        self.effect = effect; self.intensity = intensity
    }
}

/// Local presentation preferences only. No change to capture, remote consent or API payloads.
public struct JevInterventionSettings: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var effectsEnabled = false
    public var moveAfterSecondAppearance = true
    public var stages: [JevInterventionStage] = [
        .init(afterMinutes: 2, effect: .dim, intensity: 20),
        .init(afterMinutes: 5, effect: .red, intensity: 20),
        .init(afterMinutes: 10, effect: .dimAndRed, intensity: 30),
    ]
    public init() {}
    public var isValid: Bool {
        guard schemaVersion == 1, stages.count == 3 else { return false }
        var previous = 0
        for stage in stages {
            guard (1...60).contains(stage.afterMinutes), stage.afterMinutes > previous,
                  (10...40).contains(stage.intensity) else { return false }
            previous = stage.afterMinutes
        }
        return true
    }
    public func stage(at seconds: Int) -> JevInterventionStage? {
        guard isValid, effectsEnabled, seconds >= 30 else { return nil }
        return stages.last { $0.enabled && seconds >= $0.afterMinutes * 60 }
    }
    public static func duration(_ seconds: Int) -> String {
        let value = max(0, seconds)
        if value < 60 { return "\(value) secondes" }
        let minutes = value / 60, remaining = value % 60
        return remaining == 0 ? "\(minutes) min" : "\(minutes) min \(remaining) s"
    }
}

/// Stable first two presentations; subsequent presentations never reuse the last anchor.
/// Sampling is injectable for deterministic tests; layout does not follow the pointer.
public enum JevWarningAnchor: Int, CaseIterable, Sendable {
    case topRight, topLeft, bottomRight, bottomLeft, topCenter, bottomCenter
    public static func next(appearance: Int, moving: Bool, previous: Self?, sample: Int) -> Self {
        guard moving, appearance > 2 else { return .topRight }
        let choices = allCases.filter { $0 != previous }
        return choices[Int(sample.magnitude % UInt(choices.count))]
    }
}
