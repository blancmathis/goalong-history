#if os(macOS)
    import AppleSystemScreenTime
    import Foundation

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
                deviceID: deviceID
            )
            productionRepository = repository
            productionDeviceID = deviceID
            return repository
        }
    }
#endif
