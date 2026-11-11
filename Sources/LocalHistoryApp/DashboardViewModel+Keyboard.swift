import Foundation

extension DashboardViewModel {
    /// Lot 2a: the key monitor reads the navigation at the moment of the key press (an event, not a view body),
    /// so it needs no observation. The store stays reachable only through the model, as the R14b audit wants.
    @MainActor var keyboardNavigation: DashboardNavigation { navigationStore }
}
