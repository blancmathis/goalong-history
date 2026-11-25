#if os(macOS)
import Foundation

/// Generic local preferences. No hours, personal activity or AI model is installed for a new member.
struct FocusDayGuideSettings: Codable, Equatable {
    var enabled = false
    var introVersion = 0
    var remindersEnabled = true
    var quietStartMinute: Int? = nil
    var quietEndMinute: Int? = nil
    var valid: Bool {
        (0...1000).contains(introVersion)
            && ((quietStartMinute == nil && quietEndMinute == nil)
                || (quietStartMinute.map { (0..<1440).contains($0) } == true
                    && quietEndMinute.map { (0..<1440).contains($0) } == true
                    && quietStartMinute != quietEndMinute))
    }
    func isQuiet(minute: Int) -> Bool {
        guard let start = quietStartMinute, let end = quietEndMinute else { return false }
        return start < end ? (start..<end).contains(minute) : minute >= start || minute < end
    }
    enum CodingKeys: String, CodingKey { case enabled, introVersion, remindersEnabled, quietStartMinute, quietEndMinute }
    init(enabled: Bool = false, introVersion: Int = 0, remindersEnabled: Bool = true,
         quietStartMinute: Int? = nil, quietEndMinute: Int? = nil) {
        self.enabled = enabled; self.introVersion = introVersion; self.remindersEnabled = remindersEnabled
        self.quietStartMinute = quietStartMinute; self.quietEndMinute = quietEndMinute
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        introVersion = try c.decodeIfPresent(Int.self, forKey: .introVersion) ?? 0
        remindersEnabled = try c.decodeIfPresent(Bool.self, forKey: .remindersEnabled) ?? true
        quietStartMinute = try c.decodeIfPresent(Int.self, forKey: .quietStartMinute)
        quietEndMinute = try c.decodeIfPresent(Int.self, forKey: .quietEndMinute)
    }
}
#endif
