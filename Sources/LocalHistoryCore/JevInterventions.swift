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
    public static let intensityRange = 10...85
    public var schemaVersion = 3
    public var effectsEnabled = false
    public var moveAfterSecondAppearance = true
    public var stages: [JevInterventionStage] = [
        .init(afterMinutes: 2, effect: .dim, intensity: 20),
        .init(afterMinutes: 5, effect: .dimAndRed, intensity: 20),
    ]
    public init() {}
    public var isValid: Bool {
        schemaVersion == 3 && stages.count == 2 && stages.last?.effect == .dimAndRed
            && Self.validStages(stages, intensities: Self.intensityRange)
    }
    /// Validate old data against its original 40% ceiling before migrating. No
    /// migration increases an intensity or enables a previously disabled effect.
    public func migratingLegacy() -> Self? {
        guard (schemaVersion == 1 && stages.count == 3)
            || (schemaVersion == 2 && stages.count == 2 && stages.last?.effect == .dimAndRed),
              Self.validStages(stages, intensities: 10...40) else { return nil }
        var next = self
        next.schemaVersion = 3
        next.stages = Array(stages.prefix(2))
        next.stages[1].effect = .dimAndRed
        return next.isValid ? next : nil
    }
    private static func validStages(_ stages: [JevInterventionStage], intensities: ClosedRange<Int>) -> Bool {
        var previous = 0
        for stage in stages {
            guard (1...60).contains(stage.afterMinutes), stage.afterMinutes > previous,
                  intensities.contains(stage.intensity) else { return false }
            previous = stage.afterMinutes
        }
        return true
    }
    /// This changes strength only, never consent, timers, modes or stage switches.
    public mutating func applyStrength(_ strength: JevEffectStrength) {
        guard isValid else { return }
        for index in stages.indices { stages[index].intensity = strength.intensities[index] }
    }
    public static func overlayOpacity(intensity: Int) -> Double {
        Double(min(intensityRange.upperBound, max(intensityRange.lowerBound, intensity))) / 100
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

/// Explicit presets. Existing users keep their saved values until they choose one.
public enum JevEffectStrength: String, CaseIterable, Sendable {
    case moderate, strong, veryStrong
    public var title: String {
        switch self {
        case .moderate: return "Modéré"
        case .strong: return "Fort"
        case .veryStrong: return "Très fort"
        }
    }
    public var intensities: [Int] {
        switch self {
        case .moderate: return [20, 20]
        case .strong: return [45, 60]
        case .veryStrong: return [65, 85]
        }
    }
}

/// One display policy for the popup, status and menus. The underlying streak
/// continues to drive effects even while its duration is deliberately hidden.
public enum JevReminderPresentation {
    public static let durationThresholdSeconds = 600
    public static func displayedDuration(after seconds: Int) -> String? {
        guard seconds >= durationThresholdSeconds else { return nil }
        return JevInterventionSettings.duration(seconds)
    }
    public static func detail(after seconds: Int) -> String? {
        displayedDuration(after: seconds).map { "Ça fait \($0) que tu procrastines." }
    }
    public static func status(after seconds: Int) -> String {
        guard let duration = displayedDuration(after: seconds) else { return "Procrastination détectée" }
        return "Procrastination détectée · \(duration)"
    }
}

/// First presentation at top right; every subsequent presentation uses another anchor.
/// Sampling is injectable for deterministic tests; layout does not follow the pointer.
public enum JevWarningAnchor: Int, CaseIterable, Sendable {
    case topRight, topLeft, bottomRight, bottomLeft, topCenter, bottomCenter
    public static func next(appearance: Int, moving: Bool, previous: Self?, sample: Int) -> Self {
        guard moving, appearance > 1 else { return .topRight }
        let choices = allCases.filter { $0 != previous }
        return choices[Int(sample.magnitude % UInt(choices.count))]
    }
}
