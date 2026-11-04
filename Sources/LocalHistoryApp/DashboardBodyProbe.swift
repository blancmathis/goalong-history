#if os(macOS)
import SwiftUI

/// R14b: counts the body evaluations of a dashboard view, only while a test counts (`DashboardRestTests`). SwiftUI
/// calls `update()` before each evaluation of the body of the view that holds the probe. In the app it reads one Bool.
struct DashboardBodyProbe: DynamicProperty {
    static var counting = false
    private(set) static var counts: [String: Int] = [:]
    let name: String

    init(_ name: String) { self.name = name }

    func update() {
        guard Self.counting else { return }
        Self.counts[name, default: 0] += 1
    }

    static func reset() { counts = [:] }
}
#endif
