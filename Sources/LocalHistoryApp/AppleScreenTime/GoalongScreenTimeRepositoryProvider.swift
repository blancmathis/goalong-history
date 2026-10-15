#if os(macOS)
    import AppleSystemScreenTime
    import Foundation
    import LocalHistoryCore

    enum GoalongScreenTimeRepositoryProvider {
        private static let lock = NSLock()
        private static var productionRepository: AppleSystemScreenTimeRepository?
        private static var productionDeviceID: String?

        static func repository(
            rootDirectory: URL,
            deviceID: String
        ) throws -> AppleSystemScreenTimeRepository {
            let isProductionRoot = rootDirectory.standardizedFileURL
                == AppPaths.screenTimeDirectory.standardizedFileURL
            guard isProductionRoot else {
                return try AppleSystemScreenTimeRepository(
                    rootDirectory: rootDirectory,
                    deviceID: deviceID
                )
            }

            lock.lock()
            defer { lock.unlock() }
            if let productionRepository, productionDeviceID == deviceID {
                return productionRepository
            }
            let repository = try AppleSystemScreenTimeRepository(
                rootDirectory: rootDirectory,
                deviceID: deviceID,
                // The repository is a process-wide singleton: follow the system time zone so
                // "today" never goes stale after a zone change. Day files written in a previous
                // zone keep their old-zone name and stay readable as completed days.
                calendar: .autoupdatingCurrent,
                activityAdmission: { try? GoalongGlobalPause.admit() }
            )
            productionRepository = repository
            productionDeviceID = deviceID
            return repository
        }
    }
#endif
